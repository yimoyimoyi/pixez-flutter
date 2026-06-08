/// Pixiv 登录自签证书
///
/// 为 VpnService DNS 劫持 + HTTPS 代理方案提供 TLS 证书。
/// 证书 SAN 覆盖所有 Pixiv 登录相关域名，WebView 通过 onReceivedSslError 信任此证书。
///
/// 证书有效期: 2026-06-08 ~ 2036-06-05 (10 年)
/// 生成命令:
///   openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
///     -keyout pixiv_proxy.key -out pixiv_proxy.crt \
///     -subj "/CN=*.pixiv.net/O=PixEz Proxy" \
///     -addext "subjectAltName=DNS:*.pixiv.net,DNS:app-api.pixiv.net,..."
library;

import 'dart:io';

class LoginCert {
  static const _pem = '''-----BEGIN PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQCqmTUcVtDsfHR0
/cnT8rzxFyalPYoRaI0UF7o+aiqpblDDtDpGRe/Ic9U9celzDIKeVrBZM/rL6Lp8
EwTcJUfOyXgoZAhjdMavoljr6d1Tp58Q4+aqGwFoxec3zULwEZ/FZRKiSUD9MrH5
lucp/oLDYDVcAo3i4sovl6eFV4YbReUrN/Xf93dvwL1ibkqZWmypJq3QhcxKOH9q
dvBhXhoqo2sHV0Kh0qqSaFkYOcEtvZW6R+jLMnEL6hj9RviWkpD3Ry5/Z9UJK3kX
effh5IgbMMObuHyW1GdiTfgD+1zDf8JMs/a+DwYiwDQleVD4dvPxs46jTUYeAB4S
kX7yeR7XAgMBAAECggEAE8Y7ekPz5p2McC0ksl0eGoH4+ElYUilAxRX1ABwVQttn
IDApWxDrONx4WK12BmBqWYkp2sUkKnOY/h3EP/JQTv9aXrAtqr2T9DLIxNuwTGyP
CwmnqIsF0Eu0P+saebJJRzuue8Iq9s5kA87Cj8MRDC2AMeCX6rcoAXk+MT4SbOGt
zhTeUm+wPhFRRdXVEDcXUOs5GnT/rG3ND8J6eo2XM7sX7INzZ/TKiI9XAOrhkni1
pw/mbs9s2SajPPBLY3toVsm7O7p3+YRb0ayBzgDqWixWTGYCFPXJOnrdHxHe8TSG
r7PSs99Ov/89XjYsxWxVdUMmcOJBBc8GlrY0sUriiQKBgQDug1ctcN19IOPiADao
McAq/WLbdTIaLilP+atMFpJKRkm1EXSgjEhA+nuFOF8kczxs1jDXhi3ICgAGYBta
zMOiORSDunjd7Vt6ZapnQPziYEXN856smZCc/ZOfRe3OTAI39jh7c8E7gLBg7NZN
jdcXDIUejnTFLm04w/fVJa7Q+QKBgQC3Gy0D1hq2kB7HbaNTRrCH7z9QSVyN6yUf
yPgvTXBxieyRqYry+8VE94THD1LrrNRtdfUmGxVro0CVariFUCAfC4CytPhGwijz
a8FCmLEKtVnZecl9ZHDkLoB/ZfH9XrjfVnLF/vfAg0tX5hIsJ/rOO4zXPDNPi/j+
Fc5oFeYyTwKBgEX3f2ZUGpUvRcoxV9dFKOMzi4FnQrhNXE8apXZflLB3J/4Wzcie
/j8Ze4yb+cT+jPY8av1+XgW1cUZtgPjE4oq/BdaSqAwqKdCg7Dj35ncd2LxOv/hP
4A09kcWCRP1kbK4v62fDkCa9XIBCWadMeZFIWfCZx4VkViP10MjVEhA5AoGABWxL
oAJ2VhPcpYFsxemhDtWaJXGWySk+tztHhncfrm0sUYAY+mtUg19lUlP028AJpphI
w3En6EE0h3hasLAX03OOwzwy4j2b4uG9HpDRJYULfTJrMkiIQ2nRKnTFfwCQLyUr
TwvnII+C6r6IqUAh4HvJBxLkXiXCIRxaOaD0aWcCgYA6RvN1Zgq5ESbbvFxj/Bbr
3++hKiqSaISDklnHI5aV6KVTrRxZzYxsfwhmhc6XIPfC0PmNaPKkV7Fb4dXoluxR
BEItXlKiSTTEewtmjUGuh/NTudCDPCLPdoOD03A5IS2rKBbhkuDcttWMqNxyh4wl
Hh6DeS32wfOga6LAx9dedQ==
-----END PRIVATE KEY-----
-----BEGIN CERTIFICATE-----
MIIDrDCCApSgAwIBAgIUQWrOxUEyR2k6MMxaczHBi+xhAsgwDQYJKoZIhvcNAQEL
BQAwLDEUMBIGA1UEAwwLKi5waXhpdi5uZXQxFDASBgNVBAoMC1BpeEV6IFByb3h5
MB4XDTI2MDYwODE0MjMyMVoXDTM2MDYwNTE0MjMyMVowLDEUMBIGA1UEAwwLKi5w
aXhpdi5uZXQxFDASBgNVBAoMC1BpeEV6IFByb3h5MIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEAqpk1HFbQ7Hx0dP3J0/K88RcmpT2KEWiNFBe6PmoqqW5Q
w7Q6RkXvyHPVPXHpcwyCnlawWTP6y+i6fBME3CVHzsl4KGQIY3TGr6JY6+ndU6ef
EOPmqhsBaMXnN81C8BGfxWUSoklA/TKx+ZbnKf6Cw2A1XAKN4uLKL5enhVeGG0Xl
Kzf13/d3b8C9Ym5KmVpsqSat0IXMSjh/anbwYV4aKqNrB1dCodKqkmhZGDnBLb2V
ukfoyzJxC+oY/Ub4lpKQ90cuf2fVCSt5F3n34eSIGzDDm7h8ltRnYk34A/tcw3/C
TLP2vg8GIsA0JXlQ+Hbz8bOOo01GHgAeEpF+8nke1wIDAQABo4HFMIHCMB0GA1Ud
DgQWBBTDwvV4tMf/rMMQCntwWx/cyrO6pzAfBgNVHSMEGDAWgBTDwvV4tMf/rMMQ
CntwWx/cyrO6pzAPBgNVHRMBAf8EBTADAQH/MG8GA1UdEQRoMGaCCyoucGl4aXYu
bmV0ghFhcHAtYXBpLnBpeGl2Lm5ldIISYWNjb3VudHMucGl4aXYubmV0ghZvYXV0
aC5zZWN1cmUucGl4aXYubmV0gg13d3cucGl4aXYubmV0gglwaXhpdi5uZXQwDQYJ
KoZIhvcNAQELBQADggEBAFB0VTMBkViyMGj6rKuGeAWd7zcTGLPTR0m1nonmjqcq
RSuf7gvnAWtOrC6Q6wEnMuZJi/1+AbhzIbeiKZUaXpqQ2PJVVYDrgKv6S+olopYu
W3ri1WK95PBx4yQUiG3hrYZaO2sFLVpX0o4KRa0Nk148K/bMCYfd3bT9SaFXDSfg
cs98cvNjDoMo4AX46n0i8DKI7VhpHxhTJ/6UrHAh2LLlNAF5u6Bg5NKyy/238TvO
B5JIFFmRmbGx1RqhK28iKC1Z28Aj2VYCp0vHD8HOdeoPHrW4y6wX2Ia+5DP+bLFT
hvYH/fkKrZPGZ6UgiuL0yuAXkKaD1K8KZyNgq64sn3Q=
-----END CERTIFICATE-----''';

  static SecurityContext? _context;

  static SecurityContext createContext() {
    if (_context != null) return _context!;

    final bytes = _pem.codeUnits;
    _context = SecurityContext()
      ..useCertificateChainBytes(bytes)
      ..usePrivateKeyBytes(bytes);
    return _context!;
  }
}
