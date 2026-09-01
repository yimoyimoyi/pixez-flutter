use crate::api::error::RhttpError;
use crate::api::http::HttpVersionPref;
use crate::utils::socket_addr::SocketAddrDigester;
use base64::Engine;
use chrono::Duration;
use flutter_rust_bridge::{frb, DartFnFuture};
use reqwest::cookie::Jar;
use reqwest::dns::{Addrs, Name, Resolve, Resolving};
use reqwest::{tls, Certificate, Url};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::client::{EchConfig, EchMode};
use rustls::crypto::aws_lc_rs::hpke::ALL_SUPPORTED_SUITES;
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, EchConfigListBytes, PrivateKeyDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, Error as TlsError, RootCertStore, SignatureScheme};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, SocketAddr};
use std::str::FromStr;
use std::sync::{Arc, OnceLock};
use std::time::{Duration as StdDuration, Instant};
use tokio::sync::{Mutex, Notify, RwLock};
pub use tokio_util::sync::CancellationToken;

const ALIDNS_RESOLVE_ENDPOINT: &str = "https://223.5.5.5/resolve";
const ECH_BOOTSTRAP_HOST: &str = "cloudflare-ech.com";

/// T3：内置的 Cloudflare ECH config（2026-08-30 从 AliDNS HTTPS 记录获取）。
/// 用于进程内首次请求的冷启动兜底——免去首请求的 DoH 往返延迟；
/// 若已轮换失效，握手会被服务器拒绝，由 http.rs 的自动重试路径
/// 清除缓存、强制重新 DoH 后重建 client 重试一次
const BUILTIN_ECH_CONFIG_BASE64: &str = "AEX+DQBBRAAgACCnLwJmLitMBK1QAaEjyUWooIefQjI8u06YMkWVcYiNQAAEAAEAAQASY2xvdWRmbGFyZS1lY2guY29tAAA=";
/// 内置 config 兜底的缓存 TTL：仅用于 client 缓存条目的 expires_at，
/// 短于 DoH TTL 以尽快过渡到真实查询结果
const BUILTIN_ECH_CONFIG_FALLBACK_TTL: StdDuration = StdDuration::from_secs(60);

#[derive(Clone)]
pub struct ClientSettings {
    pub cookie_settings: Option<CookieSettings>,
    pub http_version_pref: HttpVersionPref,
    pub timeout_settings: Option<TimeoutSettings>,
    pub throw_on_status_code: bool,
    pub enable_ech: bool,
    pub require_ech: bool,
    pub proxy_settings: Option<ProxySettings>,
    pub redirect_settings: Option<RedirectSettings>,
    pub tls_settings: Option<TlsSettings>,
    pub dns_settings: Option<DnsSettings>,
    pub user_agent: Option<String>,
}

#[derive(Clone)]
pub struct CookieSettings {
    pub store_cookies: bool,
}

#[derive(Clone)]
pub enum ProxySettings {
    NoProxy,
    CustomProxyList(Vec<CustomProxy>),
}

#[derive(Clone)]
pub struct CustomProxy {
    pub url: String,
    pub condition: ProxyCondition,
}

#[derive(Clone)]
pub enum ProxyCondition {
    Http,
    Https,
    All,
}

#[derive(Clone)]
pub enum RedirectSettings {
    NoRedirect,
    LimitedRedirects(i32),
}

#[derive(Clone)]
pub struct TimeoutSettings {
    pub timeout: Option<Duration>,
    pub connect_timeout: Option<Duration>,
    pub keep_alive_timeout: Option<Duration>,
    pub keep_alive_ping: Option<Duration>,
}

#[derive(Clone)]
pub struct TlsSettings {
    pub root_cert_source: RootCertSource,
    pub trusted_root_certificates: Vec<Vec<u8>>,
    pub verify_certificates: bool,
    pub client_certificate: Option<ClientCertificate>,
    pub min_tls_version: Option<TlsVersion>,
    pub max_tls_version: Option<TlsVersion>,
    pub sni: bool,
}

#[derive(Clone, Copy)]
pub enum RootCertSource {
    Platform,
    Webpki,
    None,
}

#[derive(Clone)]
pub enum DnsSettings {
    StaticDns(StaticDnsSettings),
    DynamicDns(DynamicDnsSettings),
}

#[derive(Clone)]
pub struct StaticDnsSettings {
    pub overrides: HashMap<String, Vec<String>>,
    pub fallback: Option<String>,
}

#[derive(Clone)]
pub struct DynamicDnsSettings {
    /// A function that takes a hostname and returns a future that resolves to an IP address.
    resolver: Arc<dyn Fn(String) -> DartFnFuture<Vec<String>> + 'static + Send + Sync>,
}

#[derive(Clone)]
pub struct ClientCertificate {
    pub certificate: Vec<u8>,
    pub private_key: Vec<u8>,
}

#[derive(Clone, Copy)]
pub enum TlsVersion {
    Tls1_2,
    Tls1_3,
}

impl Default for ClientSettings {
    fn default() -> Self {
        ClientSettings {
            cookie_settings: None,
            http_version_pref: HttpVersionPref::All,
            timeout_settings: None,
            throw_on_status_code: true,
            enable_ech: false,
            require_ech: false,
            proxy_settings: None,
            redirect_settings: None,
            tls_settings: None,
            dns_settings: None,
            user_agent: None,
        }
    }
}

#[derive(Clone)]
pub struct RequestClient {
    pub(crate) client: reqwest::Client,
    pub(crate) settings: ClientSettings,
    pub(crate) http_version_pref: HttpVersionPref,
    pub(crate) throw_on_status_code: bool,

    /// A token that can be used to cancel all requests made by this client.
    pub(crate) cancel_token: CancellationToken,

    runtime: Arc<ClientRuntime>,
}

struct ClientRuntime {
    cookie_jar: Option<Arc<Jar>>,
    ech: Arc<EchTransport>,
    ech_clients: RwLock<HashMap<String, EchClientCacheEntry>>,
}

#[derive(Clone)]
struct EchClientCacheEntry {
    client: Option<reqwest::Client>,
    expires_at: Instant,
    /// 当前生效的 ECH config 字节（T1：用于对比复用——config 未变化时
    /// 复用现有 client，保留 HTTP/2 连接池，避免频繁重建）
    ech_config: Vec<u8>,
}

#[derive(Debug)]
struct EchLookupResult {
    ech_config: Option<Vec<u8>>,
    ttl: StdDuration,
}

struct ParsedAliDnsHttpsEch {
    ech: Vec<u8>,
    ttl: StdDuration,
}

impl RequestClient {
    pub(crate) fn new_default() -> Self {
        create_client(ClientSettings::default()).unwrap()
    }

    pub(crate) fn new(settings: ClientSettings) -> Result<RequestClient, RhttpError> {
        create_client(settings)
    }

    /// Returns the reqwest client to use for the given URL. When ECH is enabled
    /// and applicable, this resolves (and caches per-host) an ECH-configured
    /// client; otherwise the base client is returned.
    pub(crate) async fn client_for_url(&self, url: &Url) -> Result<reqwest::Client, RhttpError> {
        if !self.should_try_ech(url) {
            return Ok(self.client.clone());
        }

        let host = url
            .host_str()
            .map(str::to_ascii_lowercase)
            .unwrap_or_default();

        // 快路径：未过期缓存直接命中
        if let Some(cached) = self.runtime.ech_clients.read().await.get(&host).cloned() {
            if cached.expires_at > Instant::now() {
                return Ok(cached.client.unwrap_or_else(|| self.client.clone()));
            }
        }

        // 慢路径：查询 ECH config（T2：Single-Flight + 跨 host/跨 client 共享，
        // T3：内置 config 冷启动兜底已内部化），并发 miss 只发一次 DoH
        let ech_lookup = match self.runtime.ech.lookup_ech_config(&host).await {
            Ok(ech_lookup) => ech_lookup,
            Err(error) => {
                if self.settings.require_ech {
                    return Err(error);
                }
                return Ok(self.client.clone());
            }
        };

        // T1：决策与写入合并为单次写锁，消除并发覆盖竞态。
        // 新 config 与缓存条目一致时复用现有 client（保留 HTTP/2 连接池
        // 与 TLS 会话缓存，避免每次 TTL 过期都重建 client），仅刷新过期时间
        let mut guard = self.runtime.ech_clients.write().await;
        match ech_lookup.ech_config.as_ref() {
            Some(ech_config) => {
                if let Some(cached) = guard.get(&host) {
                    if ech_client_reusable(cached, ech_config) {
                        // 先 clone 再插入（避免对 guard 的同时可变/不可变借用）
                        let cached_client = cached.client.clone();
                        let cached_config = cached.ech_config.clone();
                        guard.insert(
                            host.clone(),
                            EchClientCacheEntry {
                                client: cached_client.clone(),
                                expires_at: Instant::now() + ech_lookup.ttl,
                                ech_config: cached_config,
                            },
                        );
                        return Ok(cached_client.unwrap_or_else(|| self.client.clone()));
                    }
                }

                let ech_client = match build_reqwest_client(
                    &self.settings,
                    &self.runtime,
                    Some(ech_config.as_slice()),
                ) {
                    Ok(client) => Some(client),
                    Err(error) => {
                        if self.settings.require_ech {
                            return Err(error);
                        }
                        return Ok(self.client.clone());
                    }
                };

                guard.insert(
                    host.clone(),
                    EchClientCacheEntry {
                        client: ech_client.clone(),
                        expires_at: Instant::now() + ech_lookup.ttl,
                        ech_config: ech_config.clone(),
                    },
                );

                Ok(ech_client.unwrap_or_else(|| self.client.clone()))
            }
            None => {
                if self.settings.require_ech {
                    return Err(RhttpError::RhttpUnknownError(
                        "ECH is required but no ECH config was found".to_string(),
                    ));
                }
                guard.insert(
                    host.clone(),
                    EchClientCacheEntry {
                        client: None,
                        expires_at: Instant::now() + ech_lookup.ttl,
                        ech_config: Vec::new(),
                    },
                );
                Ok(self.client.clone())
            }
        }
    }

    /// T3：清除指定主机的 ECH client 缓存与共享 config 缓存，
    /// 强制下一次请求重新 DoH（用于内置 config 被服务器拒绝后的自动重试）
    pub(crate) async fn invalidate_ech_for(&self, host: &str) {
        self.runtime.ech_clients.write().await.remove(host);
        self.runtime.ech.invalidate_config().await;
    }

    fn should_try_ech(&self, url: &Url) -> bool {
        if !self.settings.enable_ech && !self.settings.require_ech {
            return false;
        }

        if url.scheme() != "https" {
            return false;
        }

        let Some(host) = url.host_str() else {
            return false;
        };

        if host.parse::<IpAddr>().is_ok() {
            return false;
        }

        match self.settings.tls_settings.as_ref() {
            Some(settings) => {
                settings.sni && !matches!(settings.max_tls_version, Some(TlsVersion::Tls1_2))
            }
            None => true,
        }
    }
}

fn create_client(settings: ClientSettings) -> Result<RequestClient, RhttpError> {
    let runtime = Arc::new(ClientRuntime {
        cookie_jar: settings
            .cookie_settings
            .as_ref()
            .filter(|settings| settings.store_cookies)
            .map(|_| Arc::new(Jar::default())),
        // T2：跨 RequestClient 全局共享 ECH transport（DoH 查询与 config
        // 缓存与请求域名无关，PixEz 的 api/oauth/account 三个 client
        // 共用一份，冷启动只发一次 DoH）
        ech: EchTransport::shared(),
        ech_clients: RwLock::new(HashMap::new()),
    });

    let client = build_reqwest_client(&settings, &runtime, None)?;

    Ok(RequestClient {
        client,
        settings: settings.clone(),
        http_version_pref: settings.http_version_pref,
        throw_on_status_code: settings.throw_on_status_code,
        cancel_token: CancellationToken::new(),
        runtime,
    })
}

fn build_reqwest_client(
    settings: &ClientSettings,
    runtime: &Arc<ClientRuntime>,
    ech_config_list: Option<&[u8]>,
) -> Result<reqwest::Client, RhttpError> {
    let mut client = reqwest::Client::builder();

    if let Some(proxy_settings) = settings.proxy_settings.as_ref() {
        match proxy_settings {
            ProxySettings::NoProxy => client = client.no_proxy(),
            ProxySettings::CustomProxyList(proxies) => {
                for proxy in proxies {
                    let proxy = match proxy.condition {
                        ProxyCondition::Http => reqwest::Proxy::http(&proxy.url),
                        ProxyCondition::Https => reqwest::Proxy::https(&proxy.url),
                        ProxyCondition::All => reqwest::Proxy::all(&proxy.url),
                    }
                    .map_err(|e| {
                        RhttpError::RhttpUnknownError(format!("Error creating proxy: {e:?}"))
                    })?;
                    client = client.proxy(proxy);
                }
            }
        }
    }

    if let Some(cookie_jar) = runtime.cookie_jar.as_ref() {
        client = client.cookie_provider(cookie_jar.clone());
    }

    if let Some(redirect_settings) = settings.redirect_settings.as_ref() {
        client = match redirect_settings {
            RedirectSettings::NoRedirect => client.redirect(reqwest::redirect::Policy::none()),
            RedirectSettings::LimitedRedirects(max_redirects) => {
                client.redirect(reqwest::redirect::Policy::limited(*max_redirects as usize))
            }
        };
    }

    if let Some(timeout_settings) = settings.timeout_settings.as_ref() {
        if let Some(timeout) = timeout_settings.timeout {
            client = client.timeout(
                timeout
                    .to_std()
                    .map_err(|e| RhttpError::RhttpUnknownError(e.to_string()))?,
            );
        }

        if let Some(timeout) = timeout_settings.connect_timeout {
            client = client.connect_timeout(
                timeout
                    .to_std()
                    .map_err(|e| RhttpError::RhttpUnknownError(e.to_string()))?,
            );
        }

        if let Some(keep_alive_timeout) = timeout_settings.keep_alive_timeout {
            let timeout = keep_alive_timeout
                .to_std()
                .map_err(|e| RhttpError::RhttpUnknownError(e.to_string()))?;
            if timeout.as_millis() > 0 {
                client = client.tcp_keepalive(timeout);
                client = client.http2_keep_alive_while_idle(true);
                client = client.http2_keep_alive_timeout(timeout);
            }
        }

        if let Some(keep_alive_ping) = timeout_settings.keep_alive_ping {
            client = client.http2_keep_alive_interval(
                keep_alive_ping
                    .to_std()
                    .map_err(|e| RhttpError::RhttpUnknownError(e.to_string()))?,
            );
        }
    }

    client = match ech_config_list {
        Some(ech_config_list) => {
            client.tls_backend_preconfigured(build_ech_tls_config(settings, ech_config_list)?)
        }
        None => apply_reqwest_tls_settings(client, settings.tls_settings.as_ref())?,
    };

    client = match settings.http_version_pref {
        HttpVersionPref::Http10 | HttpVersionPref::Http11 => client.http1_only(),
        HttpVersionPref::Http2 => client.http2_prior_knowledge(),
        HttpVersionPref::Http3 => client.http3_prior_knowledge(),
        HttpVersionPref::All => client,
    };

    client = apply_dns_settings(client, settings.dns_settings.as_ref())?;

    if let Some(user_agent) = settings.user_agent.as_ref() {
        client = client.user_agent(user_agent.clone());
    }

    client
        .build()
        .map_err(|e| RhttpError::RhttpUnknownError(format!("{e:?}")))
}

fn apply_reqwest_tls_settings(
    mut client: reqwest::ClientBuilder,
    tls_settings: Option<&TlsSettings>,
) -> Result<reqwest::ClientBuilder, RhttpError> {
    let Some(tls_settings) = tls_settings else {
        // No TLS settings supplied: respect the default root cert source (Webpki).
        return Ok(client.tls_certs_only(webpki_root_certs()?));
    };

    // Caller-supplied custom roots (PEM), always layered on top.
    let custom_certs = tls_settings
        .trusted_root_certificates
        .iter()
        .map(|cert| {
            Certificate::from_pem(cert).map_err(|e| {
                RhttpError::RhttpUnknownError(format!("Error adding trusted certificate: {e:?}"))
            })
        })
        .collect::<Result<Vec<Certificate>, RhttpError>>()?;

    match tls_settings.root_cert_source {
        RootCertSource::Platform => {
            // Add custom certs if not empty, otherwise keep platform verifier as is.
            if !custom_certs.is_empty() {
                client = client.tls_certs_merge(custom_certs);
            }
        }
        RootCertSource::Webpki => {
            let mut certs = custom_certs;
            certs.extend(webpki_root_certs()?);
            client = client.tls_certs_only(certs);
        }
        RootCertSource::None => {
            client = client.tls_certs_only(custom_certs);
        }
    }

    if tls_settings.verify_certificates {
        client = client.tls_danger_accept_invalid_certs(false);
    } else {
        client = client.tls_danger_accept_invalid_certs(true);
    }

    if let Some(client_certificate) = tls_settings.client_certificate.as_ref() {
        let identity = &[
            client_certificate.certificate.as_slice(),
            "\n".as_bytes(),
            client_certificate.private_key.as_slice(),
        ]
        .concat();

        client = client.identity(
            reqwest::Identity::from_pem(identity)
                .map_err(|e| RhttpError::RhttpUnknownError(format!("{e:?}")))?,
        );
    }

    if let Some(min_tls_version) = tls_settings.min_tls_version {
        client = client.min_tls_version(match min_tls_version {
            TlsVersion::Tls1_2 => tls::Version::TLS_1_2,
            TlsVersion::Tls1_3 => tls::Version::TLS_1_3,
        });
    }

    if let Some(max_tls_version) = tls_settings.max_tls_version {
        client = client.max_tls_version(match max_tls_version {
            TlsVersion::Tls1_2 => tls::Version::TLS_1_2,
            TlsVersion::Tls1_3 => tls::Version::TLS_1_3,
        });
    }

    Ok(client.tls_sni(tls_settings.sni))
}

fn build_ech_tls_config(
    settings: &ClientSettings,
    ech_config_list: &[u8],
) -> Result<rustls::ClientConfig, RhttpError> {
    let tls_settings = settings.tls_settings.as_ref();

    if matches!(
        tls_settings.and_then(|settings| settings.max_tls_version),
        Some(TlsVersion::Tls1_2)
    ) {
        return Err(RhttpError::RhttpUnknownError(
            "ECH requires TLS 1.3 support".to_string(),
        ));
    }

    if matches!(tls_settings, Some(settings) if !settings.sni) {
        return Err(RhttpError::RhttpUnknownError(
            "ECH requires SNI to be enabled".to_string(),
        ));
    }

    let provider = rustls::crypto::CryptoProvider::get_default()
        .cloned()
        .unwrap_or_else(|| Arc::new(rustls::crypto::aws_lc_rs::default_provider()));

    let ech_config = EchConfig::new(
        EchConfigListBytes::from(ech_config_list.to_vec()),
        ALL_SUPPORTED_SUITES,
    )
    .map_err(|e| RhttpError::RhttpUnknownError(format!("Invalid ECH config: {e:?}")))?;

    let config_builder = rustls::ClientConfig::builder_with_provider(provider.clone())
        .with_ech(EchMode::from(ech_config))
        .map_err(|e| RhttpError::RhttpUnknownError(format!("Invalid ECH setup: {e:?}")))?;

    let config_builder = match tls_settings {
        Some(tls_settings) if !tls_settings.verify_certificates => config_builder
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(NoVerifier)),
        Some(tls_settings) if matches!(tls_settings.root_cert_source, RootCertSource::None) => {
            config_builder
                .with_root_certificates(build_root_store(false, &tls_settings.trusted_root_certificates)?)
        }
        Some(tls_settings) if matches!(tls_settings.root_cert_source, RootCertSource::Webpki) => {
            config_builder.with_root_certificates(build_root_store(
                true,
                &tls_settings.trusted_root_certificates,
            )?)
        }
        Some(tls_settings)
            if matches!(tls_settings.root_cert_source, RootCertSource::Platform)
                && !tls_settings.trusted_root_certificates.is_empty() =>
        {
            #[cfg(any(all(unix, not(target_os = "android")), target_os = "windows"))]
            {
                let verifier = rustls_platform_verifier::Verifier::new_with_extra_roots(
                    collect_root_cert_ders(&tls_settings.trusted_root_certificates)?,
                    provider.clone(),
                )
                .map_err(|e| RhttpError::RhttpUnknownError(format!("{e:?}")))?;

                config_builder
                    .dangerous()
                    .with_custom_certificate_verifier(Arc::new(verifier))
            }

            #[cfg(not(any(all(unix, not(target_os = "android")), target_os = "windows")))]
            {
                return Err(RhttpError::RhttpUnknownError(
                    "ECH with extra system roots is unsupported on this target".to_string(),
                ));
            }
        }
        _ => {
            let verifier = rustls_platform_verifier::Verifier::new(provider.clone())
                .map_err(|e| RhttpError::RhttpUnknownError(format!("{e:?}")))?;

            config_builder
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(verifier))
        }
    };

    let mut tls = if let Some(client_certificate) =
        tls_settings.and_then(|settings| settings.client_certificate.as_ref())
    {
        let cert_chain = collect_pem_certificates(&client_certificate.certificate)?;
        let private_key = parse_private_key(&client_certificate.private_key)?;

        config_builder
            .with_client_auth_cert(cert_chain, private_key)
            .map_err(|e| RhttpError::RhttpUnknownError(format!("{e:?}")))?
    } else {
        config_builder.with_no_client_auth()
    };

    tls.enable_sni = tls_settings.map(|settings| settings.sni).unwrap_or(true);

    match settings.http_version_pref {
        HttpVersionPref::Http10 | HttpVersionPref::Http11 => {
            tls.alpn_protocols = vec!["http/1.1".into()];
        }
        HttpVersionPref::Http2 => {
            tls.alpn_protocols = vec!["h2".into()];
        }
        HttpVersionPref::Http3 => {}
        HttpVersionPref::All => {
            tls.alpn_protocols = vec!["h2".into(), "http/1.1".into()];
        }
    }

    Ok(tls)
}

fn apply_dns_settings(
    mut client: reqwest::ClientBuilder,
    dns_settings: Option<&DnsSettings>,
) -> Result<reqwest::ClientBuilder, RhttpError> {
    match dns_settings {
        Some(DnsSettings::StaticDns(settings)) => {
            if let Some(fallback) = settings.fallback.as_ref() {
                client = client.dns_resolver(Arc::new(StaticResolver {
                    address: SocketAddr::from_str(fallback.clone().digest_ip().as_str())
                        .map_err(|e| RhttpError::RhttpUnknownError(format!("{e:?}")))?,
                }));
            }

            for (hostname, ips) in &settings.overrides {
                let mut err: Option<String> = None;
                let resolved_ips = ips
                    .iter()
                    .cloned()
                    .map(|ip| {
                        let ip_digested = ip.digest_ip();
                        SocketAddr::from_str(ip_digested.as_str()).map_err(|e| {
                            err = Some(format!("Invalid IP address: {ip_digested}. {e:?}"));
                            RhttpError::RhttpUnknownError(e.to_string())
                        })
                    })
                    .filter_map(Result::ok)
                    .collect::<Vec<SocketAddr>>();

                if let Some(error) = err {
                    return Err(RhttpError::RhttpUnknownError(error));
                }

                client = client.resolve_to_addrs(hostname, resolved_ips.as_slice());
            }
        }
        Some(DnsSettings::DynamicDns(settings)) => {
            client = client.dns_resolver(Arc::new(DynamicResolver {
                resolver: settings.resolver.clone(),
            }));
        }
        None => {}
    }

    Ok(client)
}

/// The webpki (Mozilla) root certificates bundled with the crate.
fn webpki_root_certs() -> Result<Vec<Certificate>, RhttpError> {
    webpki_root_certs::TLS_SERVER_ROOT_CERTS
        .iter()
        .map(|der| {
            Certificate::from_der(der.as_ref()).map_err(|e| {
                RhttpError::RhttpUnknownError(format!("Error adding webpki root: {e:?}"))
            })
        })
        .collect()
}

fn collect_pem_certificates(
    certificate_pem: &[u8],
) -> Result<Vec<CertificateDer<'static>>, RhttpError> {
    let certificates = CertificateDer::pem_slice_iter(certificate_pem)
        .map(|result| {
            result
                .map(|cert| cert.into_owned())
                .map_err(|_| RhttpError::RhttpUnknownError("Invalid PEM certificate".to_string()))
        })
        .collect::<Result<Vec<_>, _>>()?;

    if certificates.is_empty() {
        return Err(RhttpError::RhttpUnknownError(
            "Certificate chain is empty".to_string(),
        ));
    }

    Ok(certificates)
}

fn collect_root_cert_ders(
    trusted_root_certificates: &[Vec<u8>],
) -> Result<Vec<CertificateDer<'static>>, RhttpError> {
    let mut certificates = Vec::new();
    for cert in trusted_root_certificates {
        certificates.extend(collect_pem_certificates(cert)?);
    }
    Ok(certificates)
}

/// Builds a [`RootCertStore`], optionally seeded with the bundled webpki roots,
/// then augmented with the caller-supplied PEM roots.
fn build_root_store(
    include_webpki: bool,
    trusted_root_certificates: &[Vec<u8>],
) -> Result<RootCertStore, RhttpError> {
    let mut root_store = RootCertStore::empty();

    if include_webpki {
        for cert in webpki_root_certs::TLS_SERVER_ROOT_CERTS {
            root_store
                .add(cert.clone())
                .map_err(|e| RhttpError::RhttpUnknownError(format!("{e:?}")))?;
        }
    }

    for cert in collect_root_cert_ders(trusted_root_certificates)? {
        root_store
            .add(cert)
            .map_err(|e| RhttpError::RhttpUnknownError(format!("{e:?}")))?;
    }
    Ok(root_store)
}

fn parse_private_key(private_key: &[u8]) -> Result<PrivateKeyDer<'static>, RhttpError> {
    PrivateKeyDer::from_pem_slice(private_key)
        .or_else(|_| {
            PrivateKeyDer::try_from(private_key)
                .map(|key| key.clone_key())
                .map_err(|_| "Invalid private key".to_string())
        })
        .map_err(|e| RhttpError::RhttpUnknownError(format!("{e:?}")))
}

struct StaticResolver {
    address: SocketAddr,
}

impl Resolve for StaticResolver {
    fn resolve(&self, _: Name) -> Resolving {
        let addrs: Addrs = Box::new(vec![self.address].into_iter());
        Box::pin(futures_util::future::ready(Ok(addrs)))
    }
}

struct DynamicResolver {
    resolver: Arc<dyn Fn(String) -> DartFnFuture<Vec<String>> + 'static + Send + Sync>,
}

impl Resolve for DynamicResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let resolver = self.resolver.clone();
        Box::pin(async move {
            let ip = resolver(name.as_str().to_owned()).await;
            let ip = ip
                .into_iter()
                .map(|ip| {
                    let ip_digested = ip.digest_ip();
                    SocketAddr::from_str(ip_digested.as_str()).map_err(|e| {
                        RhttpError::RhttpUnknownError(format!(
                            "Invalid IP address: {ip_digested}. {e:?}"
                        ))
                    })
                })
                .filter_map(Result::ok)
                .collect::<Vec<SocketAddr>>();

            let addrs: Addrs = Box::new(ip.into_iter());
            Ok(addrs)
        })
    }
}

/// ECH config 缓存条目（T2：与请求域名无关，全局共享）
struct ConfigCacheEntry {
    ech_config: Arc<Vec<u8>>,
    expires_at: Instant,
}

/// ECH config 缓存状态（T2/T3）
#[derive(Default)]
struct CacheState {
    /// 有效缓存（来自 DoH 或内置 config 的后续刷新结果）
    entry: Option<Arc<ConfigCacheEntry>>,
    /// 在途 DoH 查询的通知（Single-Flight：同一时刻全局只有一个查询在跑，
    /// 查询任务完成时写回缓存并通知所有等待者；等待者被唤醒后重新读缓存）
    in_flight: Option<Arc<Notify>>,
    /// 内置 config 兜底已使用的域名（F6：每域名冷启动只兜底一次，
    /// api/oauth/account 各域名互不挤占兜底窗口）
    builtin_used_hosts: HashSet<String>,
    /// 最近一次 DoH 查询失败与时间（F1：短窗口快速失败，避免 DoH
    /// 故障时查询循环永不返回（无限加载）；窗口过期后允许重试自愈）
    last_error: Option<(Instant, RhttpError)>,
}

/// F2：DoH 失败后的快速失败窗口——窗口内直接返回错误不重试；
/// 窗口过后清除 last_error 并允许重新发起 DoH 查询（网络恢复后自愈）
const DOH_ERROR_RETRY_WINDOW: StdDuration = StdDuration::from_secs(3);

#[derive(Clone)]
struct EchTransport {
    ech_endpoint: Url,
    client: reqwest::Client,
    /// T3：编译期内置的 Cloudflare ECH config（进程首次请求冷启动兜底）
    builtin_config: Option<Vec<u8>>,
    cache: Arc<Mutex<CacheState>>,
}

impl EchTransport {
    /// 全局共享实例：跨 RequestClient 复用 DoH 查询与 ECH config 缓存
    ///（config 与请求域名无关；DoH client 构建失败时降级为内置 config 兜底）
    fn shared() -> Arc<EchTransport> {
        static GLOBAL: OnceLock<Arc<EchTransport>> = OnceLock::new();
        GLOBAL
            .get_or_init(|| {
                Arc::new(EchTransport::new().unwrap_or_else(|_| EchTransport::builtin_only()))
            })
            .clone()
    }

    fn new() -> Result<Self, RhttpError> {
        let ech_endpoint = Url::parse(ALIDNS_RESOLVE_ENDPOINT)
            .map_err(|e| RhttpError::RhttpUnknownError(e.to_string()))?;
        let client = reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            // Use the bundled Mozilla (webpki) roots instead of the platform
            // verifier. AliDNS is signed by a public CA in that bundle, and this
            // avoids depending on the Android JNI platform-verifier init, which
            // is why the bootstrap query failed on Android but not iOS.
            .tls_certs_only(webpki_root_certs()?)
            // T2：DoH 查询加超时——避免 223.5.5.5 无响应时请求无限挂起；
            // F5：失败时整体等待收敛到 ~6s（快速失败 + 3s 窗口内不重试）
            .connect_timeout(StdDuration::from_secs(3))
            .timeout(StdDuration::from_secs(6))
            .build()
            .map_err(|e| RhttpError::RhttpUnknownError(e.to_string()))?;

        Ok(Self {
            ech_endpoint,
            client,
            builtin_config: decode_builtin_ech_config(),
            cache: Arc::new(Mutex::new(CacheState::default())),
        })
    }

    /// 降级实例：仅保留内置 config 兜底（DoH client 构建失败时使用，
    /// 正常路径不会走到这里）
    fn builtin_only() -> Self {
        Self {
            ech_endpoint: Url::parse(ALIDNS_RESOLVE_ENDPOINT)
                .unwrap_or_else(|_| Url::parse("https://223.5.5.5/resolve").unwrap()),
            client: reqwest::Client::new(),
            builtin_config: decode_builtin_ech_config(),
            cache: Arc::new(Mutex::new(CacheState::default())),
        }
    }

    async fn lookup_ech_config(&self, host: &str) -> Result<EchLookupResult, RhttpError> {
        // pixiv's ECH front is served via cloudflare-ech.com; resolve the ECH
        // config from that bootstrap host regardless of the requested host.
        // 等待在途查询的兜底超时：查询任务异常挂起/panic 时（例如运行时
        // 内部错误）等待者最坏等 15s 后自行重新发起查询，避免永久挂起
        //（DoH 请求自身有 6s 总超时，正常路径不会触发该兜底）
        const WAIT_TIMEOUT: StdDuration = StdDuration::from_secs(15);

        loop {
            let notify = {
                let mut guard = self.cache.lock().await;
                let now = Instant::now();

                // F1/F2：DoH 查询失败的快速失败窗口——窗口内直接返回错误
                // 不重试（消除"请求永不返回"的无限加载）；窗口过后清除
                // last_error 并重新发起查询（网络恢复后自愈）
                if let Some((at, err)) = guard.last_error.as_ref() {
                    if now.saturating_duration_since(*at) < DOH_ERROR_RETRY_WINDOW {
                        return Err(err.clone());
                    }
                    guard.last_error = None;
                }

                // 1. 有效缓存命中（entry 可能来自 DoH 或内置 config 的后台刷新）
                if let Some(entry) = guard.entry.as_ref() {
                    if entry.expires_at > now {
                        return Ok(EchLookupResult {
                            ech_config: Some(entry.ech_config.as_ref().to_vec()),
                            ttl: entry.expires_at - now,
                        });
                    }
                }

                // 2. 已有在途查询：等待其完成（Single-Flight，避免惊群；
                //    唤醒后重新进入循环读取结果）
                if let Some(notify) = guard.in_flight.as_ref() {
                    Some(notify.clone())
                } else {
                    // 3. T3 + F6：每个域名首次查询直接用内置 config 立即建连
                    //（零 DoH 往返延迟），同时后台异步 DoH 刷新缓存。
                    // 兜底按域名记一次（api/oauth/account 互不挤占）
                    if !guard.builtin_used_hosts.contains(host) {
                        if let Some(builtin) = self.builtin_config.clone() {
                            guard.builtin_used_hosts.insert(host.to_string());
                            let notify = Arc::new(Notify::new());
                            spawn_ech_lookup(self.clone(), notify.clone());
                            guard.in_flight = Some(notify);
                            return Ok(EchLookupResult {
                                ech_config: Some(builtin),
                                ttl: BUILTIN_ECH_CONFIG_FALLBACK_TTL,
                            });
                        }
                    }

                    // 4. 发起 DoH 查询
                    let notify = Arc::new(Notify::new());
                    spawn_ech_lookup(self.clone(), notify.clone());
                    guard.in_flight = Some(notify.clone());
                    Some(notify)
                }
            };

            if let Some(notify) = notify {
                // 等待查询任务完成（complete_lookup 会写回缓存并通知）
                let waited = tokio::time::timeout(WAIT_TIMEOUT, notify.notified()).await;
                if waited.is_err() {
                    // 查询任务疑似挂死（正常路径有 10s DoH 总超时不会走到
                    // 这）：清除在途标记，允许下一次循环重新发起查询
                    let mut guard = self.cache.lock().await;
                    if guard
                        .in_flight
                        .as_ref()
                        .map(|n| Arc::ptr_eq(n, &notify))
                        .unwrap_or(false)
                    {
                        guard.in_flight = None;
                    }
                }
                continue;
            }
            // 分支 2/4 必返回 Some；分支 1/3 已直接 return
            unreachable!()
        }
    }

    /// T3：清除共享 config 缓存与在途查询（强制下一次查询重新 DoH；
    /// 在途查询任务完成后会因通知不匹配而自动丢弃结果）
    async fn invalidate_config(&self) {
        let mut guard = self.cache.lock().await;
        guard.entry = None;
        guard.in_flight = None;
        // F4：清除失败标记——验证失败的自动重试必须能立即强制重新 DoH
        guard.last_error = None;
    }

    /// 查询任务完成后的写回：若 in_flight 仍指向本任务的通知则清除
    /// 标记并写入结果缓存，然后唤醒所有等待者；已被 invalidate 则丢弃
    async fn complete_lookup(
        &self,
        notify: &Arc<Notify>,
        result: Result<EchLookupResult, RhttpError>,
    ) {
        let mut guard = self.cache.lock().await;
        let is_current = guard
            .in_flight
            .as_ref()
            .map(|n| Arc::ptr_eq(n, notify))
            .unwrap_or(false);
        if !is_current {
            return;
        }
        guard.in_flight = None;
        match result {
            Ok(lookup) => {
                if let Some(config) = lookup.ech_config.as_ref() {
                    guard.entry = Some(Arc::new(ConfigCacheEntry {
                        ech_config: Arc::new(config.clone()),
                        expires_at: Instant::now() + lookup.ttl,
                    }));
                }
                // F3：查询成功清除失败标记（不再触发快速失败）
                guard.last_error = None;
            }
            Err(err) => {
                // F3：记录失败——等待者唤醒后进入快速失败窗口，
                // 避免 DoH 故障时无限循环（请求永不返回）
                guard.last_error = Some((Instant::now(), err));
            }
        }
        // 即使查询失败也要唤醒等待者（唤醒后走快速失败或查询循环）
        notify.notify_waiters();
    }

    async fn do_doh_lookup(&self) -> Result<EchLookupResult, RhttpError> {
        let parsed = self.lookup_alidns_https_ech(ECH_BOOTSTRAP_HOST).await?;
        Ok(EchLookupResult {
            ech_config: Some(parsed.ech),
            ttl: parsed.ttl,
        })
    }

    async fn lookup_alidns_https_ech(&self, host: &str) -> Result<ParsedAliDnsHttpsEch, RhttpError> {
        let response = self
            .client
            .get(self.ech_endpoint.clone())
            .query(&[("name", host), ("type", "HTTPS")])
            .header("accept", "application/json")
            .send()
            .await
            .map_err(|e| {
                RhttpError::RhttpUnknownError(format!(
                    "AliDNS ECH request failed: {}",
                    full_error_chain(&e)
                ))
            })?;

        let status = response.status();
        if !status.is_success() {
            return Err(RhttpError::RhttpUnknownError(format!(
                "AliDNS ECH query failed with status {status}"
            )));
        }

        let body = response.bytes().await.map_err(|e| {
            RhttpError::RhttpUnknownError(format!("AliDNS ECH body read failed: {e}"))
        })?;

        parse_alidns_https_ech_response(body.as_ref())
    }
}

/// 启动一个后台 DoH 查询任务（T2：Single-Flight 的在途查询载体）。
/// cache 为 Arc<Mutex> 共享，clone 出的 transport 副本共享同一缓存；
/// 任务完成后写回结果并通过 notify 唤醒所有等待者
fn spawn_ech_lookup(transport: EchTransport, notify: Arc<Notify>) {
    tokio::spawn(async move {
        let result = transport.do_doh_lookup().await;
        transport.complete_lookup(&notify, result).await;
    });
}

/// 解码编译期内置的 ECH config（T3）。失败（常量损坏）时返回 None，
/// 查询路径会退回常规 DoH
fn decode_builtin_ech_config() -> Option<Vec<u8>> {
    base64::engine::general_purpose::STANDARD
        .decode(BUILTIN_ECH_CONFIG_BASE64)
        .ok()
}

/// T1：判断缓存条目是否可复用——新 config 与条目中 config 一致则复用
/// 现有 client（保留 HTTP/2 连接池与 TLS 会话缓存），仅刷新过期时间
fn ech_client_reusable(cached: &EchClientCacheEntry, new_config: &[u8]) -> bool {
    cached.ech_config == new_config
}

fn full_error_chain(err: &(dyn std::error::Error + 'static)) -> String {
    let mut parts = vec![err.to_string()];
    let mut source = err.source();
    while let Some(inner) = source {
        parts.push(inner.to_string());
        source = inner.source();
    }
    parts.join(" -> ")
}

fn parse_alidns_https_ech_response(body: &[u8]) -> Result<ParsedAliDnsHttpsEch, RhttpError> {
    let payload: Value = serde_json::from_slice(body)
        .map_err(|e| RhttpError::RhttpUnknownError(format!("Invalid AliDNS ECH JSON: {e}")))?;

    let status = payload
        .get("Status")
        .and_then(Value::as_u64)
        .ok_or_else(|| {
            RhttpError::RhttpUnknownError("AliDNS ECH response missing Status".to_string())
        })?;
    if status != 0 {
        return Err(RhttpError::RhttpUnknownError(format!(
            "AliDNS ECH response returned status {status}"
        )));
    }

    let answers = payload
        .get("Answer")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            RhttpError::RhttpUnknownError("AliDNS ECH response missing Answer".to_string())
        })?;

    for answer in answers {
        let Some(ttl) = answer.get("TTL").and_then(Value::as_u64) else {
            continue;
        };
        let Some(data) = answer.get("data").and_then(Value::as_str) else {
            continue;
        };
        let Some(encoded_ech) = extract_https_svc_param(data, "ech") else {
            continue;
        };

        let ech = base64::engine::general_purpose::STANDARD
            .decode(encoded_ech)
            .map_err(|e| RhttpError::RhttpUnknownError(format!("Invalid AliDNS ECH base64: {e}")))?;
        return Ok(ParsedAliDnsHttpsEch {
            ech,
            ttl: StdDuration::from_secs(ttl),
        });
    }

    Err(RhttpError::RhttpUnknownError(
        "AliDNS ECH response did not include an ech parameter".to_string(),
    ))
}

fn extract_https_svc_param<'a>(data: &'a str, key: &str) -> Option<&'a str> {
    let prefix = format!("{key}=\"");
    let start = data.find(prefix.as_str())? + prefix.len();
    let tail = &data[start..];
    let end = tail.find('"')?;
    Some(&tail[..end])
}

#[derive(Debug)]
struct NoVerifier;

impl ServerCertVerifier for NoVerifier {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, TlsError> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, TlsError> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        vec![
            SignatureScheme::RSA_PKCS1_SHA1,
            SignatureScheme::ECDSA_SHA1_Legacy,
            SignatureScheme::RSA_PKCS1_SHA256,
            SignatureScheme::ECDSA_NISTP256_SHA256,
            SignatureScheme::RSA_PKCS1_SHA384,
            SignatureScheme::ECDSA_NISTP384_SHA384,
            SignatureScheme::RSA_PKCS1_SHA512,
            SignatureScheme::ECDSA_NISTP521_SHA512,
            SignatureScheme::RSA_PSS_SHA256,
            SignatureScheme::RSA_PSS_SHA384,
            SignatureScheme::RSA_PSS_SHA512,
            SignatureScheme::ED25519,
            SignatureScheme::ED448,
        ]
    }
}

#[frb(sync)]
pub fn create_static_resolver_sync(settings: StaticDnsSettings) -> DnsSettings {
    DnsSettings::StaticDns(settings)
}

#[frb(sync)]
pub fn create_dynamic_resolver_sync(
    resolver: impl Fn(String) -> DartFnFuture<Vec<String>> + 'static + Send + Sync,
) -> DnsSettings {
    DnsSettings::DynamicDns(DynamicDnsSettings {
        resolver: Arc::new(resolver),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::http::is_ech_rejected;

    /// 测试环境安装默认 CryptoProvider（EchConfig::new 解析需要）
    fn ensure_crypto_provider() {
        static ONCE: OnceLock<()> = OnceLock::new();
        ONCE.get_or_init(|| {
            let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
        });
    }

    #[test]
    fn test_decode_builtin_ech_config() {
        let config = decode_builtin_ech_config().expect("内置 config 应可解码");
        assert!(!config.is_empty());
        // ECHConfigList 结构：u16 总长度 + ECHConfig[]（首个 ECHConfig
        // 的 version 字段为 0xFE0D，位于偏移 2）
        assert_eq!(
            u16::from_be_bytes([config[0], config[1]]) as usize,
            config.len() - 2,
            "内置 config 长度字段应自洽"
        );
        assert_eq!(&config[2..4], &[0xFE, 0x0D], "内置 config 应为 ECHConfigList 格式");
        // 且能被 rustls 解析为有效 ECH config（T3 兜底可用性）
        ensure_crypto_provider();
        let ech = EchConfig::new(EchConfigListBytes::from(config), ALL_SUPPORTED_SUITES);
        assert!(ech.is_ok(), "内置 config 应可被 rustls 解析: {ech:?}");
    }

    #[test]
    fn test_ech_client_reusable() {
        // T1：仅当新 config 与缓存条目一致时才复用现有 client
        let entry = EchClientCacheEntry {
            client: Some(reqwest::Client::new()),
            expires_at: Instant::now(),
            ech_config: vec![1, 2, 3],
        };
        assert!(ech_client_reusable(&entry, &[1, 2, 3]), "相同 config 应复用");
        assert!(
            !ech_client_reusable(&entry, &[1, 2, 4]),
            "不同 config 应重建"
        );
        assert!(
            !ech_client_reusable(&entry, &[]),
            "空 config（查询无结果）不应视为复用"
        );
    }

    #[test]
    fn test_parse_alidns_https_ech_response() {
        // 2026-08-30 从 223.5.5.5 获取的真实响应（ech 字段与
        // BUILTIN_ECH_CONFIG_BASE64 同源）
        let body = br#"{"Status":0,"TC":false,"RD":true,"RA":true,"Question":[{"name":"cloudflare-ech.com.","type":65}],"Answer":[{"name":"cloudflare-ech.com.","TTL":192,"type":65,"data":"1 . alpn=\"h3,h2\" ipv4hint=\"104.18.10.118,104.18.11.118\" ech=\"AEX+DQBBRAAgACCnLwJmLitMBK1QAaEjyUWooIefQjI8u06YMkWVcYiNQAAEAAEAAQASY2xvdWRmbGFyZS1lY2guY29tAAA=\" ipv6hint=\"2606:4700::6812:a76,2606:4700::6812:b76\""}]}"#;
        let parsed = parse_alidns_https_ech_response(body).expect("真实响应应成功解析");
        assert_eq!(parsed.ttl, StdDuration::from_secs(192));
        // 解析出的 ech 字节应与内置 config 一致（同一数据源）
        assert_eq!(parsed.ech, decode_builtin_ech_config().unwrap());
    }

    #[test]
    fn test_extract_https_svc_param() {
        let data = r#"1 . alpn="h3,h2" ech="AEX+DQ" ipv4hint="1.2.3.4""#;
        assert_eq!(extract_https_svc_param(data, "ech"), Some("AEX+DQ"));
        assert_eq!(extract_https_svc_param(data, "alpn"), Some("h3,h2"));
        assert_eq!(extract_https_svc_param(data, "ipv4hint"), Some("1.2.3.4"));
        assert_eq!(extract_https_svc_param(data, "missing"), None);
    }

    #[tokio::test]
    async fn test_lookup_builtin_cold_start() {
        // T3：进程内首次查询应无网络依赖地立即返回内置 config（冷启动
        // 零 DoH 往返）；后台刷新任务在 runtime 结束时自动取消
        let transport = EchTransport::builtin_only();
        let first = transport
            .lookup_ech_config("app-api.pixiv.net")
            .await
            .expect("内置 config 冷启动应成功");
        let config = first.ech_config.expect("应返回内置 config");
        assert_eq!(config, decode_builtin_ech_config().unwrap());
        // F6：dom 第一次兜底后置入 builtin_used_hosts
        let guard = transport.cache.lock().await;
        assert!(
            guard.builtin_used_hosts.contains("app-api.pixiv.net"),
            "内置 config 使用后应标记 builtin_used_hosts"
        );
        drop(guard);
    }

    #[tokio::test]
    async fn test_builtin_per_host_once() {
        // F6：内置 config 兜底按域名各记一次——oauth 消耗后，
        // api 首次仍然能兜底（这才是"api 用 ECH 不挂"的关键）
        let transport = EchTransport::builtin_only();
        let oauth = transport
            .lookup_ech_config("oauth.secure.pixiv.net")
            .await
            .expect("oauth 首次应兜底");
        assert_eq!(
            oauth.ech_config.unwrap(),
            decode_builtin_ech_config().unwrap()
        );

        // api 的第二次 lookup 可能命中后台 DoH 刷新的新 config（key 已
        // 轮换时字节不同）——两者都有效；验证拿到的是有效 ECHConfigList
        let api = transport
            .lookup_ech_config("app-api.pixiv.net")
            .await
            .expect("api 不应因 oauth 先消耗 builtin 而卡死失败");
        let api_config = api.ech_config.expect("api 应拿到 config");
        assert!(
            api_config.len() >= 4,
            "config 长度异常: {}",
            api_config.len()
        );
        assert_eq!(
            &api_config[2..4],
            &[0xFE, 0x0D],
            "api 应拿到有效 ECHConfigList（version 0xFE0D）"
        );
        assert_eq!(
            u16::from_be_bytes([api_config[0], api_config[1]]) as usize,
            api_config.len() - 2,
            "config 长度字段应自洽"
        );

        let guard = transport.cache.lock().await;
        // oauth 实际消耗了 builtin 兜底（已标记）；api 若后台 DoH 先完成
        // 则直接命中 entry（不会消耗 builtin，也不应被标记）——两种时序
        // 都正确，仅断言 oauth 标记作为"兜底已生效"证据
        assert!(
            guard.builtin_used_hosts.contains("oauth.secure.pixiv.net"),
            "oauth 域名应已标记"
        );
        drop(guard);
    }

    #[tokio::test]
    async fn test_lookup_fast_fail_on_doh_error() {
        // F1/F2：DoH 失败进入快速失败窗口 → lookup 立即返回错误，
        // 不再无限循环（无网络依赖：预置 last_error + 预置在途任务，
        // 直接断言快速失败路径，不等待真实 DoH）
        let transport = EchTransport::builtin_only();
        // 先让某个域名消耗 builtin，避免走入兜底分支
        let _ = transport
            .lookup_ech_config("app-api.pixiv.net")
            .await
            .expect("内置兜底应成功");
        // 预置 DoH 失败标记（模拟 DoH 查询失败后写入的 last_error）
        transport.cache.lock().await.last_error = Some((
            Instant::now(),
            RhttpError::RhttpUnknownError("模拟 DoH 失败".to_string()),
        ));
        // 同一域名再次查询：应命中快速失败窗口，立即返回错误（不发起
        // 新 DoH、不循环），错误内容与预置一致
        let start = Instant::now();
        let result = transport.lookup_ech_config("app-api.pixiv.net").await;
        let fast_failed = matches!(
            result,
            Err(RhttpError::RhttpUnknownError(ref msg)) if msg == "模拟 DoH 失败"
        );
        assert!(fast_failed, "快速失败应返回预置错误，实际: {result:?}");
        assert!(
            start.elapsed() < StdDuration::from_millis(500),
            "快速失败应即时返回（避免无限加载），实际耗时: {:?}",
            start.elapsed()
        );
    }

    /// 端到端验证：模拟 PixEz api 服务的完整 ECH settings（与
    /// pixez_network_settings.dart forHost ech 分支一致），真实执行
    /// DoH 查询 + ECH 握手 + HTTP 请求全链路。
    /// 手动运行：cargo test -- --ignored test_ech_end_to_end_api
    #[tokio::test]
    #[ignore = "真实网络端到端验证（手动运行，需联网）"]
    async fn test_ech_end_to_end_api() {
        let mut overrides = HashMap::new();
        overrides.insert(
            "app-api.pixiv.net".to_string(),
            vec![
                "104.18.10.118".to_string(),
                "104.18.11.118".to_string(),
            ],
        );
        let settings = ClientSettings {
            enable_ech: true,
            require_ech: true,
            tls_settings: Some(TlsSettings {
                root_cert_source: RootCertSource::Webpki,
                trusted_root_certificates: vec![],
                verify_certificates: true,
                client_certificate: None,
                min_tls_version: None,
                max_tls_version: None,
                sni: true,
            }),
            timeout_settings: Some(TimeoutSettings {
                timeout: None,
                connect_timeout: None,
                keep_alive_timeout: Some(chrono::Duration::seconds(60)),
                keep_alive_ping: Some(chrono::Duration::seconds(25)),
            }),
            dns_settings: Some(DnsSettings::StaticDns(StaticDnsSettings {
                overrides,
                fallback: None,
            })),
            ..ClientSettings::default()
        };
        let client = RequestClient::new(settings).expect("client 创建失败");
        let url = Url::parse(
            "https://app-api.pixiv.net/v1/illust/recommended?filter=for_ios&include_ranking_label=true",
        )
        .unwrap();

        // 模拟 http.rs 的 T3 自动重试路径：首次握手（builtin/旧 config）
        // 失败 → invalidate → 重新 lookup（DoH 新 config）→ 重试
        let host = "app-api.pixiv.net";

        let first = tokio::time::timeout(StdDuration::from_secs(15), async {
            let effective = client
                .client_for_url(&url)
                .await
                .map_err(|e| e.to_string())?;
            let request = effective
                .get(url.clone())
                .build()
                .map_err(|e| e.to_string())?;
            effective.execute(request).await.map_err(|e| e.to_string())
        })
        .await;
        println!("首次请求（builtin config）结果: {first:?}");
        // 首次失败不应挂起
        assert!(first.is_ok(), "首次请求 15s 超时（挂起！）");
        let first_err = first.unwrap();
        if let Err(err_msg) = &first_err {
            println!(
                "首次失败是否 ECH 拒绝特征: {}",
                is_ech_rejected(&RhttpError::RhttpInvalidCertificateError(err_msg.clone()))
            );
        }

        // 重试路径：invalidate → 强制 DoH 新 config → 重建 → 重试
        client.invalidate_ech_for(host).await;
        let retry = tokio::time::timeout(StdDuration::from_secs(20), async {
            let effective = client
                .client_for_url(&url)
                .await
                .map_err(|e| e.to_string())?;
            let request = effective
                .get(url)
                .build()
                .map_err(|e| e.to_string())?;
            effective.execute(request).await.map_err(|e| e.to_string())
        })
        .await;

        match retry {
            Ok(Ok(response)) => {
                println!(
                    "✅ 重试成功（DoH 新 config）：status = {}",
                    response.status()
                );
            }
            Ok(Err(e)) => {
                println!("❌ 重试失败: {e}");
                panic!("ECH 重试失败: {e}");
            }
            Err(_) => {
                println!("❌ 重试 20s 超时（挂起！）");
                panic!("ECH 重试超时——请求挂起");
            }
        }
    }
}
