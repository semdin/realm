//! `realm_server selfcheck`: a QUIC loopback round trip (TLS handshake, one
//! reliable stream, unreliable datagrams) that proves the transport builds
//! and runs on every platform CI covers.

use std::error::Error;
use std::sync::Arc;
use std::time::{Duration, Instant};

use bytes::Bytes;
use quinn::crypto::rustls::{QuicClientConfig, QuicServerConfig};
use quinn::{ClientConfig, Endpoint, ServerConfig};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};

pub type AnyResult<T> = Result<T, Box<dyn Error + Send + Sync>>;

pub async fn run() -> AnyResult<()> {
    let certified = rcgen::generate_simple_self_signed(vec!["localhost".to_owned()])?;
    let cert = CertificateDer::from(certified.cert);
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(
        certified.signing_key.serialize_der(),
    ));

    let mut server_tls = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![cert.clone()], key)?;
    server_tls.alpn_protocols = vec![realm_proto::ALPN.to_vec()];
    let server_config =
        ServerConfig::with_crypto(Arc::new(QuicServerConfig::try_from(server_tls)?));
    let server = Endpoint::server(server_config, "127.0.0.1:0".parse()?)?;
    let address = server.local_addr()?;

    let echo = tokio::spawn(async move {
        let incoming = server.accept().await.ok_or("server endpoint closed")?;
        let connection = incoming.await?;
        let (mut send, mut recv) = connection.accept_bi().await?;
        let hello = recv.read_to_end(64).await?;
        send.write_all(&hello).await?;
        send.finish()?;
        while let Ok(datagram) = connection.read_datagram().await {
            connection.send_datagram(datagram)?;
        }
        AnyResult::Ok(())
    });

    let mut roots = rustls::RootCertStore::empty();
    roots.add(cert)?;
    let mut client_tls = rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    client_tls.alpn_protocols = vec![realm_proto::ALPN.to_vec()];
    let mut client = Endpoint::client("127.0.0.1:0".parse()?)?;
    client.set_default_client_config(ClientConfig::new(Arc::new(QuicClientConfig::try_from(
        client_tls,
    )?)));

    let started = Instant::now();
    let connection = client.connect(address, "localhost")?.await?;
    let handshake = started.elapsed();

    let (mut send, mut recv) = connection.open_bi().await?;
    send.write_all(b"hello").await?;
    send.finish()?;
    let reply = recv.read_to_end(64).await?;
    if reply != b"hello" {
        return Err("reliable stream echo mismatch".into());
    }

    // Datagrams are unreliable by design: resend until one echo arrives.
    let probe = Bytes::from_static(b"tick");
    let echoed = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            connection.send_datagram(probe.clone())?;
            if let Ok(Ok(datagram)) =
                tokio::time::timeout(Duration::from_millis(200), connection.read_datagram()).await
            {
                return AnyResult::Ok(datagram);
            }
        }
    })
    .await
    .map_err(|_| "no datagram echo within 5 s")??;
    if echoed != probe {
        return Err("datagram echo mismatch".into());
    }

    println!(
        "selfcheck ok: protocol v{}, sim {} Hz, handshake {:.1} ms, rtt {:.2} ms, max datagram {} bytes",
        realm_proto::PROTOCOL_VERSION,
        realm_sim::SIM_HZ,
        handshake.as_secs_f64() * 1000.0,
        connection.rtt().as_secs_f64() * 1000.0,
        connection.max_datagram_size().unwrap_or(0),
    );
    connection.close(0u32.into(), b"done");
    client.wait_idle().await;
    echo.await??;
    Ok(())
}
