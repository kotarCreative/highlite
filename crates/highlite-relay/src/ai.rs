//! Provider-specific transport hidden behind a single generation interface.

use std::time::Duration;

use base64::{Engine, engine::general_purpose::STANDARD};
use reqwest::{Client, Response, redirect::Policy};
use serde_json::{Value, json};

use crate::providers::{ProviderKind, ResolvedProvider};

pub(crate) fn client(timeout_seconds: u64) -> Result<Client, String> {
    Client::builder()
        .timeout(Duration::from_secs(timeout_seconds))
        .redirect(Policy::none())
        .build()
        .map_err(|_| "could not initialize HTTP client".to_owned())
}

pub(crate) async fn bounded_json(mut response: Response) -> Result<Value, String> {
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "could not read remote response")?
    {
        if bytes.len() + chunk.len() > 256 * 1024 {
            return Err("remote response exceeds the size limit".to_owned());
        }
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes).map_err(|_| "remote response was not valid JSON".to_owned())
}

pub(crate) async fn generate(
    provider: &ResolvedProvider,
    instructions: &str,
    evidence: &str,
    image: Option<&[u8]>,
) -> Result<String, String> {
    let client = client(120)?;
    let (path, body) = generation_body(provider, instructions, evidence, image);
    let mut request = client
        .post(format!("{}/{path}", provider.base_url))
        .json(&body);
    drop(body);
    if let Some(key) = &provider.api_key {
        request = if provider.kind == ProviderKind::Anthropic {
            request.header("x-api-key", key)
        } else {
            request.bearer_auth(key)
        };
    }
    if provider.kind == ProviderKind::Anthropic {
        request = request.header("anthropic-version", "2023-06-01");
    }
    let response = request
        .send()
        .await
        .map_err(|_| "AI request failed or timed out; no provider response was logged")?;
    if !response.status().is_success() {
        return Err(format!(
            "AI request failed (HTTP {}); check the provider credentials, model capabilities, and limits",
            response.status().as_u16()
        ));
    }
    generation_text(provider.kind, bounded_json(response).await?)
}

fn generation_body(
    provider: &ResolvedProvider,
    instructions: &str,
    evidence: &str,
    image: Option<&[u8]>,
) -> (&'static str, Value) {
    let mut content = vec![json!({"type": "text", "text": evidence})];
    if let Some(image) = image {
        let encoded = STANDARD.encode(image);
        content.push(if provider.kind == ProviderKind::Anthropic {
            json!({"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": encoded}})
        } else {
            json!({"type": "image_url", "image_url": {"url": format!("data:image/png;base64,{encoded}")}})
        });
    }
    match provider.kind {
        ProviderKind::Anthropic => (
            "messages",
            json!({
                "model": provider.model, "max_tokens": 4096, "system": instructions,
                "messages": [{"role": "user", "content": content}],
            }),
        ),
        ProviderKind::Openai | ProviderKind::OpenaiCompatible => {
            let mut body = json!({"model": provider.model, "messages": [
                {"role": "system", "content": instructions}, {"role": "user", "content": content},
            ]});
            if provider.kind == ProviderKind::Openai {
                body["response_format"] = json!({"type": "json_object"});
                body["max_completion_tokens"] = json!(4096);
            } else {
                // Compatible endpoints need not support OpenAI's JSON mode.
                body["max_tokens"] = json!(4096);
            }
            ("chat/completions", body)
        }
    }
}

fn generation_text(kind: ProviderKind, response: Value) -> Result<String, String> {
    let text = if kind == ProviderKind::Anthropic {
        if response["stop_reason"] != "end_turn" {
            return Err("AI response was incomplete or refused; no draft was accepted".to_owned());
        }
        response["content"].as_array().map(|parts| {
            parts
                .iter()
                .filter(|part| part["type"] == "text")
                .filter_map(|part| part["text"].as_str())
                .collect::<String>()
        })
    } else {
        let choice = &response["choices"][0];
        if choice["finish_reason"] != "stop" || !choice["message"]["refusal"].is_null() {
            return Err("AI response was incomplete or refused; no draft was accepted".to_owned());
        }
        choice["message"]["content"].as_str().map(str::to_owned)
    };
    text.filter(|text| !text.trim().is_empty())
        .ok_or_else(|| "AI response contained no text".to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adapters_keep_the_same_generation_contract() {
        for kind in [
            ProviderKind::Openai,
            ProviderKind::Anthropic,
            ProviderKind::OpenaiCompatible,
        ] {
            let provider = ResolvedProvider {
                id: "test".to_owned(),
                kind,
                model: "model".to_owned(),
                base_url: "https://example.com".to_owned(),
                api_key: Some("secret".to_owned()),
            };
            let (path, body) = generation_body(
                &provider,
                "system instructions",
                "capture evidence",
                Some(b"image"),
            );
            assert!(!body.to_string().contains("secret"));
            assert_eq!(body["model"], "model");
            if kind == ProviderKind::Anthropic {
                assert_eq!(path, "messages");
                assert_eq!(body["system"], "system instructions");
                assert_eq!(body["messages"][0]["content"][1]["type"], "image");
                assert_eq!(generation_text(kind, json!({"stop_reason":"end_turn", "content":[{"type":"text", "text":"result"}]})).unwrap(), "result");
            } else {
                assert_eq!(path, "chat/completions");
                assert_eq!(body["messages"][1]["content"][1]["type"], "image_url");
                assert_eq!(
                    body["response_format"].is_null(),
                    kind == ProviderKind::OpenaiCompatible
                );
                assert_eq!(generation_text(kind, json!({"choices":[{"finish_reason":"stop", "message":{"content":"result"}}]})).unwrap(), "result");
                assert!(generation_text(kind, json!({"choices":[{"finish_reason":"length", "message":{"content":"partial"}}]})).is_err());
            }
        }
    }
}
