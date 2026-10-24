//! Jira Cloud publishing. Model output never controls destinations or field mappings.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct JiraTarget {
    pub site_url: String,
    pub email: String,
    pub project_key: String,
    pub issue_type_id: String,
    #[serde(default)]
    pub extra_fields: Map<String, Value>,
}

impl JiraTarget {
    pub fn validate(&self) -> Result<(), String> {
        let url = reqwest::Url::parse(&self.site_url).map_err(|_| "invalid Jira site URL")?;
        let local = url.host_str().is_some_and(|host| {
            host == "localhost"
                || host
                    .trim_matches(['[', ']'])
                    .parse::<std::net::IpAddr>()
                    .is_ok_and(|ip| ip.is_loopback())
        });
        if !(url.scheme() == "https" || (url.scheme() == "http" && local))
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
            || !matches!(url.path(), "" | "/")
        {
            return Err("Jira site must be an HTTPS origin without credentials, path, query, or fragment (loopback HTTP is allowed for testing)".to_owned());
        }
        if self.email.trim().is_empty()
            || self.email.len() > 256
            || self.email.chars().any(char::is_control)
            || !self.email.contains('@')
        {
            return Err("a Jira account email is required".to_owned());
        }
        if self.project_key.is_empty()
            || self.project_key.len() > 64
            || !self
                .project_key
                .bytes()
                .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_')
        {
            return Err(
                "Jira project key must contain uppercase letters, digits, or '_'".to_owned(),
            );
        }
        if self.issue_type_id.is_empty()
            || self.issue_type_id.len() > 32
            || !self.issue_type_id.bytes().all(|byte| byte.is_ascii_digit())
        {
            return Err("Jira issue type must be a numeric ID".to_owned());
        }
        if serde_json::to_vec(&self.extra_fields)
            .map_err(|_| "invalid Jira extra fields")?
            .len()
            > 16 * 1024
            || self.extra_fields.keys().any(|key| {
                matches!(
                    key.as_str(),
                    "summary" | "description" | "project" | "issuetype"
                ) || key.is_empty()
                    || key.len() > 128
                    || !key
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
            })
        {
            return Err("extra Jira fields must be small, static field mappings and cannot override summary, description, project, or issuetype".to_owned());
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct IssueDraft {
    pub summary: String,
    pub description: String,
}

impl IssueDraft {
    pub fn validate(&self) -> Result<(), String> {
        if self.summary.trim().is_empty()
            || self.summary.chars().count() > 255
            || self.summary.chars().any(char::is_control)
        {
            return Err("issue summary must be 1-255 characters on a single line".to_owned());
        }
        if self.description.trim().is_empty()
            || self.description.len() > 32 * 1024
            || self
                .description
                .chars()
                .any(|character| character.is_control() && !matches!(character, '\n' | '\r' | '\t'))
        {
            return Err("issue description must be non-empty text within 32 KiB".to_owned());
        }
        Ok(())
    }
}

pub(crate) enum PublishOutcome {
    Published { key: String, url: String },
    Rejected(String),
    Unknown(String),
}

pub(crate) async fn create_issue(
    target: &JiraTarget,
    token: &str,
    draft: &IssueDraft,
    session_id: &str,
) -> PublishOutcome {
    let client = match crate::ai::client(30) {
        Ok(client) => client,
        Err(error) => return PublishOutcome::Rejected(error),
    };
    let mut fields = target.extra_fields.clone();
    fields.insert("project".to_owned(), json!({"key": target.project_key}));
    fields.insert("issuetype".to_owned(), json!({"id": target.issue_type_id}));
    fields.insert("summary".to_owned(), json!(draft.summary));
    fields.insert("description".to_owned(), document(&draft.description));
    let payload = json!({"fields": fields, "properties": [{"key": "highlite.session", "value": {"sessionId": session_id, "recipe": "jira-issue", "version": "1.0.0"}}]});
    let response = match client.post(format!("{}/rest/api/3/issue", target.site_url.trim_end_matches('/')))
        .basic_auth(&target.email, Some(token)).json(&payload).send().await
    {
        Ok(response) => response,
        Err(_) => return PublishOutcome::Unknown("Jira request failed or timed out. Check Jira for an existing issue before taking further action; publishing will not be retried automatically.".to_owned()),
    };
    let status = response.status();
    if status.as_u16() != 201 {
        let message = format!(
            "Jira returned HTTP {}. Check permissions, project, issue type, and required extra fields. Remote response bodies are not logged.",
            status.as_u16()
        );
        return if status.is_client_error() {
            PublishOutcome::Rejected(message)
        } else {
            PublishOutcome::Unknown(format!(
                "{message} Check Jira for an existing issue before taking further action."
            ))
        };
    }
    let body = match crate::ai::bounded_json(response).await {
        Ok(body) => body,
        Err(_) => return PublishOutcome::Unknown("Jira accepted the request but its response could not be read. Check Jira for the created issue.".to_owned()),
    };
    let Some(key) = body["key"].as_str().filter(|key| valid_issue_key(key)) else {
        return PublishOutcome::Unknown("Jira accepted the request but returned no valid issue key. Check Jira for the created issue.".to_owned());
    };
    PublishOutcome::Published {
        key: key.to_owned(),
        url: format!("{}/browse/{key}", target.site_url.trim_end_matches('/')),
    }
}

fn valid_issue_key(key: &str) -> bool {
    key.len() <= 100
        && key.rsplit_once('-').is_some_and(|(prefix, number)| {
            !prefix.is_empty()
                && !number.is_empty()
                && prefix
                    .bytes()
                    .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_')
                && number.bytes().all(|byte| byte.is_ascii_digit())
        })
}

fn document(text: &str) -> Value {
    let paragraphs: Vec<Value> = text
        .lines()
        .map(|line| {
            let content = if line.is_empty() {
                vec![]
            } else {
                vec![json!({"type": "text", "text": line})]
            };
            json!({"type": "paragraph", "content": content})
        })
        .collect();
    json!({"version": 1, "type": "doc", "content": paragraphs})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn treats_generated_content_as_text_not_jira_markup() {
        let adf = document("Steps\n<script>untrusted</script>\n\nExpected");
        assert_eq!(adf["type"], "doc");
        assert_eq!(
            adf["content"][1]["content"][0]["text"],
            "<script>untrusted</script>"
        );
        assert!(valid_issue_key("TEAM-123"));
        assert!(!valid_issue_key("https://evil.example"));
        assert!(!valid_issue_key("TEAM-123/redirect"));
        assert!(
            IssueDraft {
                summary: "bad\nsummary".to_owned(),
                description: "body".to_owned()
            }
            .validate()
            .is_err()
        );
    }
}
