//! The smallest HTTP/1.1 the realm's services need: one JSON request per
//! connection, size-capped and timed out by the caller, one answer (JSON;
//! `respond_raw` for the few that are not, such as the coordinator's
//! operator panel and its Prometheus text), then the connection closes. The
//! coordinator's admin surface and the login service both speak it; neither
//! keeps a connection alive.

use std::collections::HashMap;

use serde_json::{Value, json};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub const MAX_HEADER_BYTES: usize = 8 * 1024;
pub const MAX_BODY_BYTES: usize = 64 * 1024;

/// A request: method, path (no query, no trailing slash), headers by
/// lowercase name, and the JSON body (`{}` when empty).
pub struct Request {
    pub method: String,
    pub path: String,
    pub headers: HashMap<String, String>,
    pub body: Value,
}

impl Request {
    pub fn header(&self, name: &str) -> &str {
        self.headers.get(name).map_or("", String::as_str)
    }

    /// The token of an `Authorization: Bearer <token>` header.
    pub fn bearer(&self) -> &str {
        self.header("authorization")
            .strip_prefix("Bearer ")
            .unwrap_or("")
            .trim()
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

/// Reads one request; Err((status, why)) for a malformed or oversized one.
pub async fn read_request<S: AsyncRead + Unpin>(
    stream: &mut S,
) -> Result<Request, (u16, &'static str)> {
    let mut buf = Vec::new();
    let mut chunk = [0_u8; 4096];
    let header_end = loop {
        if let Some(at) = find(&buf, b"\r\n\r\n") {
            break at;
        }
        if buf.len() > MAX_HEADER_BYTES {
            return Err((431, "headers too large"));
        }
        let n = stream
            .read(&mut chunk)
            .await
            .map_err(|_| (400, "bad request"))?;
        if n == 0 {
            return Err((400, "bad request"));
        }
        buf.extend_from_slice(&chunk[..n]);
    };
    let head = std::str::from_utf8(&buf[..header_end]).map_err(|_| (400, "bad request"))?;
    let mut lines = head.split("\r\n");
    let mut first = lines.next().unwrap_or("").split(' ');
    let method = first.next().unwrap_or("").to_owned();
    let mut path = first
        .next()
        .unwrap_or("")
        .split('?')
        .next()
        .unwrap_or("")
        .to_owned();
    if path.len() > 1 && path.ends_with('/') {
        path.pop();
    }
    let mut headers = HashMap::new();
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            headers.insert(name.trim().to_ascii_lowercase(), value.trim().to_owned());
        }
    }
    let length: usize = match headers.get("content-length") {
        Some(v) => v.parse().map_err(|_| (400, "bad content-length"))?,
        None => 0,
    };
    if length > MAX_BODY_BYTES {
        return Err((413, "body too large"));
    }
    let mut body = buf[header_end + 4..].to_vec();
    while body.len() < length {
        let n = stream
            .read(&mut chunk)
            .await
            .map_err(|_| (400, "bad request"))?;
        if n == 0 {
            return Err((400, "body cut short"));
        }
        body.extend_from_slice(&chunk[..n]);
    }
    body.truncate(length);
    let body = if body.iter().all(u8::is_ascii_whitespace) {
        json!({})
    } else {
        serde_json::from_slice(&body).map_err(|_| (400, "body is not json"))?
    };
    Ok(Request {
        method,
        path,
        headers,
        body,
    })
}

/// Writes the answer and closes the writing side.
pub async fn respond<S: AsyncWrite + Unpin>(stream: &mut S, status: u16, body: &Value) {
    respond_raw(
        stream,
        status,
        "application/json",
        &[],
        body.to_string().as_bytes(),
    )
    .await;
}

/// Writes an answer that is not JSON (the operator panel's page, the
/// Prometheus text) with its content type and any extra headers, and
/// closes the writing side.
pub async fn respond_raw<S: AsyncWrite + Unpin>(
    stream: &mut S,
    status: u16,
    content_type: &str,
    headers: &[(&str, &str)],
    body: &[u8],
) {
    let text = match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        413 => "Payload Too Large",
        426 => "Upgrade Required",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        _ => "Error",
    };
    let mut head = format!(
        "HTTP/1.1 {status} {text}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n",
        body.len()
    );
    for (name, value) in headers {
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    head.push_str("\r\n");
    let _ = stream.write_all(head.as_bytes()).await;
    let _ = stream.write_all(body).await;
    let _ = stream.shutdown().await;
}

/// Compares two secrets in time that does not depend on where they differ.
pub fn same(a: &[u8], b: &[u8]) -> bool {
    let mut diff = a.len() ^ b.len();
    for i in 0..a.len().max(b.len()) {
        let x = a.get(i).copied().unwrap_or(0);
        let y = b.get(i).copied().unwrap_or(0);
        diff |= usize::from(x ^ y);
    }
    diff == 0
}

/// One request to a service (a client of the same small HTTP): (status,
/// JSON body).
pub async fn call(
    address: &str,
    method: &str,
    path: &str,
    headers: &[(&str, &str)],
    body: &Value,
) -> std::io::Result<(u16, Value)> {
    let mut stream = tokio::net::TcpStream::connect(address).await?;
    let payload = body.to_string();
    let mut head = format!("{method} {path} HTTP/1.1\r\nHost: {address}\r\n");
    for (k, v) in headers {
        head.push_str(&format!("{k}: {v}\r\n"));
    }
    head.push_str(&format!(
        "Content-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        payload.len()
    ));
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(payload.as_bytes()).await?;
    let mut text = Vec::new();
    stream.read_to_end(&mut text).await?;
    let text = String::from_utf8_lossy(&text);
    let status = text
        .split(' ')
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let body = text.split_once("\r\n\r\n").map_or("{}", |(_, b)| b);
    Ok((status, serde_json::from_str(body).unwrap_or(Value::Null)))
}
