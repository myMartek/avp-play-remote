//! Signs an app bundle with a development certificate, without Apple's `codesign` and without a keychain.
//!
//! Three steps, each callable from Swift through the C functions at the end:
//!   1. `new_key`: a fresh RSA key and the request Apple turns into a certificate.
//!   2. (Apple answers the request with a certificate; that is not done here.)
//!   3. `sign_app`: sign the bundle in place with that key and certificate.
//!
//! The signing itself is the `apple-codesign` library (MPL-2.0).

use {
    apple_codesign::{
        cryptography::InMemoryPrivateKey, AppleCertificateBuilder, AppleCodesignError, CertificateProfile, SettingsScope, SigningSettings,
        UnifiedSigner,
    },
    rsa::pkcs8::{EncodePrivateKey, LineEnding},
    std::{
        ffi::{c_char, CStr},
        path::Path,
    },
    x509_certificate::{CapturedX509Certificate, InMemorySigningKeyPair, X509CertificateBuilder},
};

type Failure = Box<dyn std::error::Error>;

fn read_key(path: &Path) -> Result<InMemoryPrivateKey, Failure> {
    let parsed = pem::parse(std::fs::read(path)?)?;
    Ok(match parsed.tag() {
        "RSA PRIVATE KEY" => InMemoryPrivateKey::from_pkcs1_der(parsed.contents())?,
        _ => InMemoryPrivateKey::from_pkcs8_der(parsed.contents())?,
    })
}

/// The certificate at `path`, as Apple hands it out (DER) or as PEM.
fn read_certificate(path: &Path) -> Result<CapturedX509Certificate, Failure> {
    let data = std::fs::read(path)?;
    Ok(if data.starts_with(b"-----BEGIN") {
        CapturedX509Certificate::from_pem(data)?
    } else {
        CapturedX509Certificate::from_der(data)?
    })
}

/// Writes a new RSA-2048 key (PKCS#8 PEM, mode 600) and the certificate request for it (PEM).
pub fn new_key(key_out: &Path, request_out: &Path) -> Result<(), Failure> {
    let private_key = rsa::RsaPrivateKey::new(&mut rand::thread_rng(), 2048)?;
    let key_pem = private_key.to_pkcs8_pem(LineEnding::LF)?;
    write_private(key_out, key_pem.as_bytes())?;

    let key = read_key(key_out)?;
    let mut builder = X509CertificateBuilder::default();
    builder
        .subject()
        .append_common_name_utf8_string("Install Probe")
        .map_err(|e| format!("request subject: {e:?}"))?;
    let request = builder.create_certificate_signing_request(&key)?.encode_pem()?;
    std::fs::write(request_out, request)?;
    Ok(())
}

/// A certificate nobody trusts, for checking on the Mac that the signature is well formed. Never for a device.
pub fn self_signed(key_out: &Path, certificate_out: &Path, team: &str) -> Result<(), Failure> {
    let private_key = rsa::RsaPrivateKey::new(&mut rand::thread_rng(), 2048)?;
    write_private(key_out, private_key.to_pkcs8_pem(LineEnding::LF)?.as_bytes())?;
    let mut builder = X509CertificateBuilder::default();
    builder.apple_certificate_profile(CertificateProfile::AppleDevelopment)?;
    builder.apple_subject(team, "Install Probe Test", "DE")?;
    builder.validity_duration(chrono::Duration::days(2));
    let pair = InMemorySigningKeyPair::from_pkcs8_der(pem::parse(std::fs::read(key_out)?)?.contents())?;
    let certificate = builder.create_with_key_pair(&pair)?;
    std::fs::write(certificate_out, certificate.encode_der()?)?;
    Ok(())
}

fn write_private(path: &Path, data: &[u8]) -> Result<(), Failure> {
    use std::{io::Write, os::unix::fs::OpenOptionsExt};
    let _ = std::fs::remove_file(path);
    let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)?;
    file.write_all(data)?;
    Ok(())
}

/// Signs the app bundle at `app` in place. `entitlements` is the XML the main program is signed with.
/// The provisioning profile has to be in the bundle already (`embedded.mobileprovision`): it is sealed like any file.
pub fn sign_app(app: &Path, key: &Path, certificate: &Path, entitlements: Option<&Path>) -> Result<String, Failure> {
    let key = read_key(key)?;
    let certificate = read_certificate(certificate)?;
    let subject = certificate.subject_common_name().unwrap_or_default();

    let mut settings = SigningSettings::default();
    settings.set_signing_key(&key, certificate);
    settings.chain_apple_certificates();
    let mut team = settings.set_team_id_from_signing_certificate().map(str::to_owned);
    if let Some(path) = entitlements {
        settings.set_entitlements_xml(SettingsScope::Main, std::fs::read_to_string(path)?)?;
        if team.is_none() {
            // A certificate Apple did not issue names no team the library accepts; the entitlements do.
            team = settings
                .entitlements_plist(SettingsScope::Main)
                .and_then(|plist| plist.as_dictionary()?.get("com.apple.developer.team-identifier")?.as_string())
                .map(str::to_owned);
            if let Some(team) = &team {
                settings.set_team_id(team);
            }
        }
    }
    let team = team.unwrap_or_default();
    UnifiedSigner::new(settings).sign_path_in_place(app).map_err(|e: AppleCodesignError| e.to_string())?;
    Ok(format!("{subject}, team {team}"))
}

// ---- C interface -----------------------------------------------------------------------------------------------

unsafe fn path<'a>(text: *const c_char) -> &'a Path {
    Path::new(CStr::from_ptr(text).to_str().unwrap_or(""))
}

/// Copies `text` into the caller's buffer, cut to fit, always terminated.
unsafe fn report(text: &str, buffer: *mut c_char, size: usize) {
    if buffer.is_null() || size == 0 {
        return;
    }
    let bytes = text.as_bytes();
    let mut length = bytes.len().min(size - 1);
    while !text.is_char_boundary(length) {
        length -= 1;
    }
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), buffer as *mut u8, length);
    *buffer.add(length) = 0;
}

/// 0 on success. `message` receives the error text, or nothing.
///
/// # Safety
/// The paths are C strings; `message` has room for `message_size` bytes.
#[no_mangle]
pub unsafe extern "C" fn probe_sign_new_key(
    key_out: *const c_char,
    request_out: *const c_char,
    message: *mut c_char,
    message_size: usize,
) -> i32 {
    match new_key(path(key_out), path(request_out)) {
        Ok(()) => 0,
        Err(error) => {
            report(&error.to_string(), message, message_size);
            1
        }
    }
}

/// 0 on success. `message` receives who signed (certificate name and team), or the error text.
///
/// # Safety
/// The paths are C strings, `entitlements` may be null; `message` has room for `message_size` bytes.
#[no_mangle]
pub unsafe extern "C" fn probe_sign_app(
    app: *const c_char,
    key: *const c_char,
    certificate: *const c_char,
    entitlements: *const c_char,
    message: *mut c_char,
    message_size: usize,
) -> i32 {
    let entitlements = if entitlements.is_null() { None } else { Some(path(entitlements)) };
    match sign_app(path(app), path(key), path(certificate), entitlements) {
        Ok(signer) => {
            report(&signer, message, message_size);
            0
        }
        Err(error) => {
            report(&error.to_string(), message, message_size);
            1
        }
    }
}
