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
        self.validate_connection()?;
        self.validate_destination()
    }

    pub fn validate_connection(&self) -> Result<(), String> {
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
        Ok(())
    }

    fn validate_destination(&self) -> Result<(), String> {
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

#[derive(Serialize)]
pub(crate) struct JiraChoice {
    pub value: String,
    pub name: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ConnectionInfo {
    pub display_name: String,
    pub projects: Vec<JiraChoice>,
}

async fn read_metadata(
    client: &reqwest::Client,
    target: &JiraTarget,
    token: &str,
    path: &str,
) -> Result<Value, String> {
    let response = client
        .get(format!("{}{path}", target.site_url))
        .basic_auth(&target.email, Some(token))
        .send()
        .await
        .map_err(|_| {
            "Could not reach Jira. Check the site URL and network connection.".to_owned()
        })?;
    let status = response.status().as_u16();
    if status != 200 {
        return Err(match status {
            401 => "Jira rejected the credentials. Check the account email and API token.".to_owned(),
            403 => "Jira denied access. Check this account's Jira access and project permissions.".to_owned(),
            404 => "Jira endpoint not found. Use the Jira Cloud site URL, without a page path.".to_owned(),
            429 => "Jira is rate limiting requests. Wait a moment and try again.".to_owned(),
            300..=399 => "Jira redirected the request. Enter the final Jira Cloud site URL; redirects are not followed.".to_owned(),
            _ => format!("Jira returned HTTP {status}. Try again later."),
        });
    }
    crate::ai::bounded_json(response).await.map_err(|_| {
        "Jira returned unreadable metadata. Check that this is a Jira Cloud site.".to_owned()
    })
}

// Use local offsets, never Jira's nextPage URL, so credentials cannot follow an
// upstream-provided link. Bound both the page count and total request duration.
async fn choices(
    client: &reqwest::Client,
    target: &JiraTarget,
    token: &str,
    project: Option<&str>,
) -> Result<Vec<JiraChoice>, String> {
    let mut result = Vec::new();
    let mut offset = 0;
    for _ in 0..50 {
        let path = match project {
            Some(key) => format!(
                "/rest/api/3/issue/createmeta/{key}/issuetypes?startAt={offset}&maxResults=100"
            ),
            None => format!(
                "/rest/api/3/project/search?action=create&orderBy=name&startAt={offset}&maxResults=100"
            ),
        };
        let body = read_metadata(client, target, token, &path).await?;
        let entries = body[if project.is_some() {
            "issueTypes"
        } else {
            "values"
        }]
        .as_array()
        .ok_or("Jira returned an invalid list of choices.")?;
        for entry in entries {
            let value = entry[if project.is_some() { "id" } else { "key" }]
                .as_str()
                .ok_or("Jira returned a choice without an identifier.")?;
            let name = entry["name"]
                .as_str()
                .filter(|name| !name.trim().is_empty() && name.len() <= 512)
                .ok_or("Jira returned a choice without a valid name.")?;
            let valid = if project.is_some() {
                !value.is_empty()
                    && value.len() <= 32
                    && value.bytes().all(|byte| byte.is_ascii_digit())
            } else {
                valid_project_key(value)
            };
            if !valid {
                return Err("Jira returned an invalid choice identifier.".to_owned());
            }
            // Subtasks require a parent, which this issue recipe does not supply.
            if entry["subtask"].as_bool() != Some(true) {
                result.push(JiraChoice {
                    value: value.to_owned(),
                    name: name.to_owned(),
                });
            }
        }
        offset += entries.len();
        if body["isLast"].as_bool() == Some(true)
            || body["total"]
                .as_u64()
                .is_some_and(|total| offset as u64 >= total)
            || (body["total"].is_null() && body["isLast"].is_null() && entries.len() < 100)
        {
            return Ok(result);
        }
        if entries.is_empty() {
            return Err("Jira pagination stopped early. Try loading the choices again.".to_owned());
        }
    }
    Err("This Jira site has too many choices to load safely.".to_owned())
}

pub(crate) fn valid_project_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 64
        && key
            .bytes()
            .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_')
}

pub(crate) async fn test_connection(
    target: &JiraTarget,
    token: &str,
) -> Result<ConnectionInfo, String> {
    let client = crate::ai::client(10)?;
    let user = read_metadata(&client, target, token, "/rest/api/3/myself").await?;
    if user["accountId"].as_str().is_none_or(str::is_empty)
        || user["active"].as_bool() == Some(false)
    {
        return Err(
            "Jira did not confirm an active account. Check the site URL and credentials."
                .to_owned(),
        );
    }
    let display_name = user["displayName"]
        .as_str()
        .filter(|name| name.len() <= 512)
        .unwrap_or("Jira account")
        .to_owned();
    let projects = choices(&client, target, token, None).await?;
    Ok(ConnectionInfo {
        display_name,
        projects,
    })
}

pub(crate) async fn issue_types(
    target: &JiraTarget,
    token: &str,
) -> Result<Vec<JiraChoice>, String> {
    if !valid_project_key(&target.project_key) {
        return Err("Choose a valid Jira project first.".to_owned());
    }
    choices(
        &crate::ai::client(10)?,
        target,
        token,
        Some(&target.project_key),
    )
    .await
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct IssueDraft {
    pub summary: String,
    pub description: String,
    #[serde(default)]
    pub attachments: Vec<String>,
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
        if self.attachments.len() > crate::attachments::MAX_ATTACHMENTS
            || self
                .attachments
                .iter()
                .any(|id| !crate::attachments::valid_id(id))
        {
            return Err(format!(
                "issue attachments must be up to {} capture image identifiers",
                crate::attachments::MAX_ATTACHMENTS
            ));
        }
        let mut seen = std::collections::HashSet::new();
        if self.attachments.iter().any(|id| !seen.insert(id)) {
            return Err("each issue attachment can be selected only once".to_owned());
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
    recipe_version: &str,
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
    let payload = json!({"fields": fields, "properties": [{"key": "highlite.session", "value": {"sessionId": session_id, "recipe": "jira-issue", "version": recipe_version}}]});
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

pub(crate) enum AttachmentOutcome {
    Uploaded,
    Rejected(String),
    Unknown(String),
}

pub(crate) async fn upload_attachment(
    target: &JiraTarget,
    token: &str,
    issue_key: &str,
    file_name: &str,
    bytes: &[u8],
) -> AttachmentOutcome {
    let client = match crate::ai::client(30) {
        Ok(client) => client,
        Err(error) => return AttachmentOutcome::Rejected(error),
    };
    let part = match reqwest::multipart::Part::bytes(bytes.to_vec())
        .file_name(file_name.to_owned())
        .mime_str("image/png")
    {
        Ok(part) => part,
        Err(_) => {
            return AttachmentOutcome::Rejected(
                "Could not prepare the Jira attachment request.".to_owned(),
            );
        }
    };
    let form = reqwest::multipart::Form::new().part("file", part);
    let response = match client
        .post(format!(
            "{}/rest/api/3/issue/{issue_key}/attachments",
            target.site_url.trim_end_matches('/')
        ))
        .basic_auth(&target.email, Some(token))
        .header("X-Atlassian-Token", "no-check")
        .multipart(form)
        .send()
        .await
    {
        Ok(response) => response,
        Err(_) => {
            return AttachmentOutcome::Unknown(
                "Jira did not confirm the attachment upload (request failed or timed out). Check the issue before uploading it again."
                    .to_owned(),
            );
        }
    };
    let status = response.status().as_u16();
    if status == 200 {
        return AttachmentOutcome::Uploaded;
    }
    let message = match status {
        401 => "Jira rejected the credentials while adding the attachment.".to_owned(),
        403 => {
            "Jira denied adding the attachment. Check this account's Create attachments permission and issue access."
                .to_owned()
        }
        404 => "Jira did not find the issue for the attachment upload.".to_owned(),
        413 => "Jira rejected the attachment because it exceeds the site's attachment size limit."
            .to_owned(),
        429 => "Jira is rate limiting attachment uploads. Try again later.".to_owned(),
        300..=399 => {
            "Jira redirected the attachment upload; redirects are not followed.".to_owned()
        }
        _ => format!("Jira returned HTTP {status} while adding the attachment."),
    };
    AttachmentOutcome::Rejected(message)
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
                description: "body".to_owned(),
                attachments: Vec::new(),
            }
            .validate()
            .is_err()
        );
        assert!(
            IssueDraft {
                summary: "Valid".to_owned(),
                description: "body".to_owned(),
                attachments: vec!["../contact-sheet.png".to_owned()],
            }
            .validate()
            .is_err()
        );
    }
}
