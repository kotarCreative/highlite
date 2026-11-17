//! A deliberately small loopback HTTP client for readiness and auth probes.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::time::Duration;

#[derive(Debug)]
pub struct Response {
    pub status: u16,
    pub body: String,
}

pub fn get_loopback(
    port: u16,
    path: &str,
    bearer: Option<&str>,
    timeout: Duration,
) -> Result<Response, String> {
    send(port, "GET", path, bearer, &[], &[], timeout)
}

pub fn send(
    port: u16,
    method: &str,
    path: &str,
    bearer: Option<&str>,
    headers: &[(&str, &str)],
    body: &[u8],
    timeout: Duration,
) -> Result<Response, String> {
    let address = SocketAddr::from(([127, 0, 0, 1], port));
    let mut stream = TcpStream::connect_timeout(&address, timeout)
        .map_err(|error| format!("could not connect to loopback relay: {error}"))?;
    stream
        .set_read_timeout(Some(timeout))
        .map_err(|error| error.to_string())?;
    stream
        .set_write_timeout(Some(timeout))
        .map_err(|error| error.to_string())?;

    let mut request = format!(
        "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\nAccept: application/json\r\n"
    );
    if let Some(token) = bearer {
        request.push_str("Authorization: Bearer ");
        request.push_str(token);
        request.push_str("\r\n");
    }
    for (name, value) in headers {
        request.push_str(name);
        request.push_str(": ");
        request.push_str(value);
        request.push_str("\r\n");
    }
    if !body.is_empty() {
        request.push_str(&format!("Content-Length: {}\r\n", body.len()));
    }
    request.push_str("\r\n");

    stream
        .write_all(request.as_bytes())
        .and_then(|()| stream.write_all(body))
        .map_err(|error| format!("could not write to loopback relay: {error}"))?;

    let mut response = Vec::new();
    let mut buffer = [0u8; 8192];
    loop {
        match stream.read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => {
                response.extend_from_slice(&buffer[..read]);
                if response.len() > 2 * 1024 * 1024 {
                    return Err("loopback relay response was too large".to_owned());
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                break;
            }
            Err(error) => return Err(format!("could not read loopback relay response: {error}")),
        }
    }
    parse_response(&response)
}

fn parse_response(bytes: &[u8]) -> Result<Response, String> {
    let split = bytes
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .ok_or_else(|| "loopback relay returned an incomplete HTTP response".to_owned())?;
    let headers = std::str::from_utf8(&bytes[..split])
        .map_err(|error| format!("loopback relay headers were invalid UTF-8: {error}"))?;
    let status = headers
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|value| value.parse::<u16>().ok())
        .ok_or_else(|| "loopback relay returned an invalid HTTP status line".to_owned())?;
    let body = String::from_utf8_lossy(&bytes[split + 4..]).into_owned();
    Ok(Response { status, body })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::thread;

    #[test]
    fn parses_a_minimal_response() {
        let response = parse_response(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok").unwrap();
        assert_eq!(response.status, 200);
        assert_eq!(response.body, "ok");
    }

    #[test]
    fn sends_authorization_header() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buffer = [0u8; 1024];
            let read = stream.read(&mut buffer).unwrap();
            let request = String::from_utf8_lossy(&buffer[..read]);
            assert!(request.starts_with("GET /v1/sessions HTTP/1.1\r\n"));
            assert!(request.contains("Authorization: Bearer secret-token"));
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
                .unwrap();
        });
        let response = get_loopback(
            port,
            "/v1/sessions",
            Some("secret-token"),
            Duration::from_secs(1),
        )
        .unwrap();
        assert_eq!(response.status, 200);
        server.join().unwrap();
    }
}
