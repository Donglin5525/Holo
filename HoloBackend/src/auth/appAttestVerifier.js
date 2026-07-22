import {
  X509Certificate,
  createHash,
  createPublicKey,
  timingSafeEqual,
  verify as verifySignature,
} from "node:crypto";

const APP_ATTEST_NONCE_OID_DER = Buffer.from("06092a864886f763640802", "hex");
const DEVELOPMENT_AAGUID = Buffer.from("appattestdevelop", "utf8");
const PRODUCTION_AAGUID = Buffer.concat([Buffer.from("appattest", "utf8"), Buffer.alloc(7)]);

export function createAppAttestVerifier(options = {}) {
  const teamId = String(options.teamId ?? "").trim();
  const bundleId = String(options.bundleId ?? "").trim();
  const environment = options.environment === "development" ? "development" : "production";
  const roots = (options.rootCertificates ?? []).map((value) => new X509Certificate(value));
  if (!teamId || !bundleId) {
    throw new Error("App Attest team ID and bundle ID are required");
  }
  if (roots.length === 0) {
    throw new Error("At least one trusted Apple App Attest root certificate is required");
  }
  const appIdHash = sha256(Buffer.from(teamId + "." + bundleId, "utf8"));

  return {
    verifyAttestation({ keyId, attestationObject, challenge }) {
      const decoded = decodeCborBase64(attestationObject);
      if (decoded.fmt !== "apple-appattest") {
        throw new Error("Unexpected App Attest format");
      }
      const authData = requireBuffer(decoded.authData, "authData");
      const attStmt = requireObject(decoded.attStmt, "attStmt");
      const certificateChain = requireArray(attStmt.x5c, "x5c").map((item) =>
        new X509Certificate(requireBuffer(item, "x5c certificate")),
      );
      const leaf = validateCertificateChain(certificateChain, roots);
      const clientDataHash = sha256(Buffer.from(String(challenge), "utf8"));
      const expectedNonce = sha256(Buffer.concat([authData, clientDataHash]));
      const actualNonce = extractAppAttestNonce(leaf.raw);
      assertEqual(actualNonce, expectedNonce, "App Attest nonce mismatch");

      const parsed = parseAttestedAuthenticatorData(authData);
      assertEqual(parsed.rpIdHash, appIdHash, "App Attest app identity mismatch");
      assertEqual(parsed.credentialId, decodeBase64(keyId), "App Attest credential mismatch");
      const expectedAaguid = environment === "development" ? DEVELOPMENT_AAGUID : PRODUCTION_AAGUID;
      assertEqual(parsed.aaguid, expectedAaguid, "App Attest environment mismatch");

      const publicKeyPoint = extractEcPublicKeyPoint(leaf.publicKey);
      assertEqual(sha256(publicKeyPoint), decodeBase64(keyId), "App Attest key ID mismatch");
      return {
        publicKeyPem: leaf.publicKey.export({ type: "spki", format: "pem" }).toString(),
        receipt: Buffer.isBuffer(attStmt.receipt) ? attStmt.receipt.toString("base64") : null,
        signCount: parsed.signCount,
        environment,
      };
    },

    verifyAssertion({ publicKeyPem, assertionObject, challenge }) {
      const decoded = decodeCborBase64(assertionObject);
      const signature = requireBuffer(decoded.signature, "signature");
      const authData = requireBuffer(decoded.authenticatorData, "authenticatorData");
      if (authData.length < 37) throw new Error("Authenticator data is truncated");
      assertEqual(authData.subarray(0, 32), appIdHash, "App Attest app identity mismatch");
      const signCount = authData.readUInt32BE(33);
      const clientDataHash = sha256(Buffer.from(String(challenge), "utf8"));
      const signedPayload = Buffer.concat([authData, clientDataHash]);
      const valid = verifySignature(
        "sha256",
        signedPayload,
        createPublicKey(publicKeyPem),
        signature,
      );
      if (!valid) throw new Error("App Attest assertion signature is invalid");
      return { signCount };
    },
  };
}

function validateCertificateChain(chain, roots) {
  if (chain.length < 2) throw new Error("App Attest certificate chain is incomplete");
  const now = Date.now();
  for (const certificate of chain) {
    if (Date.parse(certificate.validFrom) > now || Date.parse(certificate.validTo) < now) {
      throw new Error("App Attest certificate is outside its validity period");
    }
  }
  for (let index = 0; index < chain.length - 1; index += 1) {
    if (!chain[index].verify(chain[index + 1].publicKey)) {
      throw new Error("App Attest certificate chain signature is invalid");
    }
  }
  const last = chain.at(-1);
  const trusted = roots.some((root) =>
    last.fingerprint256 === root.fingerprint256 || last.verify(root.publicKey),
  );
  if (!trusted) throw new Error("App Attest certificate chain is not trusted");
  return chain[0];
}

function parseAttestedAuthenticatorData(authData) {
  if (authData.length < 55) throw new Error("Authenticator data is truncated");
  const rpIdHash = authData.subarray(0, 32);
  const flags = authData[32];
  if ((flags & 0x40) === 0) throw new Error("Authenticator data has no attested credential");
  const signCount = authData.readUInt32BE(33);
  const aaguid = authData.subarray(37, 53);
  const credentialLength = authData.readUInt16BE(53);
  const credentialStart = 55;
  const credentialEnd = credentialStart + credentialLength;
  if (credentialEnd > authData.length) throw new Error("Credential ID is truncated");
  return {
    rpIdHash,
    signCount,
    aaguid,
    credentialId: authData.subarray(credentialStart, credentialEnd),
  };
}

function extractEcPublicKeyPoint(publicKey) {
  const spki = publicKey.export({ type: "spki", format: "der" });
  for (let index = spki.length - 65; index >= 0; index -= 1) {
    if (spki[index] === 0x04 && spki.length - index === 65) {
      return spki.subarray(index);
    }
  }
  throw new Error("App Attest public key is not an uncompressed P-256 key");
}

function extractAppAttestNonce(certificateDer) {
  const oidIndex = certificateDer.indexOf(APP_ATTEST_NONCE_OID_DER);
  if (oidIndex < 0) throw new Error("App Attest nonce extension is missing");
  const searchEnd = Math.min(certificateDer.length, oidIndex + 160);
  for (let index = oidIndex + APP_ATTEST_NONCE_OID_DER.length; index < searchEnd; index += 1) {
    if (certificateDer[index] !== 0x04) continue;
    const parsed = readDerLength(certificateDer, index + 1);
    if (!parsed || parsed.length !== 32) continue;
    const start = parsed.nextOffset;
    if (start + 32 <= certificateDer.length) return certificateDer.subarray(start, start + 32);
  }
  throw new Error("App Attest nonce extension is malformed");
}

function readDerLength(buffer, offset) {
  if (offset >= buffer.length) return null;
  const first = buffer[offset];
  if ((first & 0x80) === 0) return { length: first, nextOffset: offset + 1 };
  const bytes = first & 0x7f;
  if (bytes === 0 || bytes > 4 || offset + bytes >= buffer.length) return null;
  let length = 0;
  for (let index = 0; index < bytes; index += 1) {
    length = (length << 8) | buffer[offset + 1 + index];
  }
  return { length, nextOffset: offset + 1 + bytes };
}

function decodeCborBase64(value) {
  const buffer = decodeBase64(value);
  const state = { offset: 0 };
  const decoded = decodeCborItem(buffer, state);
  if (state.offset !== buffer.length) throw new Error("CBOR contains trailing bytes");
  return requireObject(decoded, "CBOR root");
}

function decodeCborItem(buffer, state) {
  if (state.offset >= buffer.length) throw new Error("CBOR is truncated");
  const initial = buffer[state.offset++];
  const major = initial >> 5;
  const additional = initial & 0x1f;
  const length = readCborLength(buffer, state, additional);
  if (major === 0) return length;
  if (major === 1) return -1 - length;
  if (major === 2) return readBytes(buffer, state, length);
  if (major === 3) return readBytes(buffer, state, length).toString("utf8");
  if (major === 4) {
    return Array.from({ length }, () => decodeCborItem(buffer, state));
  }
  if (major === 5) {
    const result = {};
    for (let index = 0; index < length; index += 1) {
      const key = decodeCborItem(buffer, state);
      if (typeof key !== "string") throw new Error("CBOR map key must be text");
      result[key] = decodeCborItem(buffer, state);
    }
    return result;
  }
  if (major === 7 && additional === 20) return false;
  if (major === 7 && additional === 21) return true;
  if (major === 7 && additional === 22) return null;
  throw new Error("Unsupported CBOR value");
}

function readCborLength(buffer, state, additional) {
  if (additional < 24) return additional;
  if (additional === 24) return readUnsigned(buffer, state, 1);
  if (additional === 25) return readUnsigned(buffer, state, 2);
  if (additional === 26) return readUnsigned(buffer, state, 4);
  throw new Error("Unsupported CBOR length");
}

function readUnsigned(buffer, state, bytes) {
  if (state.offset + bytes > buffer.length) throw new Error("CBOR is truncated");
  let value = 0;
  for (let index = 0; index < bytes; index += 1) {
    value = value * 256 + buffer[state.offset++];
  }
  return value;
}

function readBytes(buffer, state, length) {
  if (!Number.isSafeInteger(length) || length < 0 || state.offset + length > buffer.length) {
    throw new Error("CBOR byte string is truncated");
  }
  const value = buffer.subarray(state.offset, state.offset + length);
  state.offset += length;
  return value;
}

function decodeBase64(value) {
  if (typeof value !== "string" || value.length === 0 || value.length > 2_000_000) {
    throw new Error("Base64 value is invalid");
  }
  const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
  return Buffer.from(normalized, "base64");
}

function sha256(value) {
  return createHash("sha256").update(value).digest();
}

function assertEqual(actual, expected, message) {
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
    throw new Error(message);
  }
}

function requireBuffer(value, label) {
  if (!Buffer.isBuffer(value)) throw new Error(label + " must be bytes");
  return value;
}

function requireArray(value, label) {
  if (!Array.isArray(value)) throw new Error(label + " must be an array");
  return value;
}

function requireObject(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value) || Buffer.isBuffer(value)) {
    throw new Error(label + " must be an object");
  }
  return value;
}
