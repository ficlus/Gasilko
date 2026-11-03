/**
 * M15A.2 pure server-side verifier. NO HTTP/JWT/SQL/nonce issuance/consumption.
 * Inputs named credential/context MUST come from a future trusted boundary, never
 * from client registration claims. Types and successful math do not establish origin,
 * live authorization, consent, one-time use or an authoritative inactive binding.
 */
export type DeviceProofScopeV1 = Readonly<{
  account: string; organization: string; incident: string;
  deployment: string; vehicle: string; authorityEpisode: string;
}>;
export type DeviceProofChallengeV1 = Readonly<{
  protocolVersion: 1; audience: string; recoveryEpoch: string; scope: DeviceProofScopeV1;
  credentialId: string; publicKeySha256: string; policyVersion: string;
  policyDocumentSha256: string; preciseAudienceSha256: string;
  issueOperationId: string; confirmOperationId: string; challengeId: string;
  nonceBase64Url: string; issuedAtSeconds: string; expiresAtSeconds: string;
  expectedIncidentVersion: string; expectedDeploymentVersion: string;
  expectedVehicleVersion: string; reservedGeneration: string;
}>;
export type DeviceCredentialSnapshotV1 = Readonly<{
  protocolVersion: 1; credentialId: string; scope: DeviceProofScopeV1;
  generation: string; lifecycleStatus: "INACTIVE" | "REVOKED";
  publicKeySha256: string; publicKeySpkiDer: Uint8Array;
}>;
export type DeviceProofContextV1 = Readonly<{
  account: string; organization: string; scope: DeviceProofScopeV1;
  audience: string; recoveryEpoch: string; policyVersion: string;
  policyDocumentSha256: string; preciseAudienceSha256: string;
  incidentVersion: string; deploymentVersion: string; vehicleVersion: string;
  generation: string; serverNowSeconds: string;
}>;
export type DeviceProofSubmissionV1 = Readonly<{
  protocolVersion: 1; credentialId: string; challengeId: string;
  issueOperationId: string; confirmOperationId: string;
  signatureEncoding: "P1363_RAW64"; signatureRaw: Uint8Array; transcript: Uint8Array;
}>;
export type DeviceSignatureEvidenceV1 = Readonly<{
  kind: "SIGNATURE_VALID_ONLY"; protocolVersion: 1;
  credentialId: string; challengeId: string;
  issueOperationId: string; confirmOperationId: string; reservedGeneration: string;
  publicKeySha256: string; transcriptSha256: string; signatureSha256: string;
}>;
export type DeviceProofFailureCode =
  | "INVALID_INPUT" | "INVALID_ENCODING" | "INVALID_PUBLIC_KEY" | "INVALID_SIGNATURE"
  | "UNSUPPORTED_PROTOCOL" | "CREDENTIAL_MISMATCH" | "CREDENTIAL_REVOKED"
  | "SCOPE_MISMATCH" | "TRANSCRIPT_MISMATCH" | "EXPIRED" | "CRYPTO_UNAVAILABLE";

export class DeviceProofFailure extends Error {
  constructor(readonly code: DeviceProofFailureCode) { super(code); this.name = "DeviceProofFailure"; }
}
const MAX_I64 = 9223372036854775807n;
const P = 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffffffffn;
const N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n;
const B = 0x5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604bn;
const SPKI_PREFIX = new Uint8Array([
  0x30,0x59,0x30,0x13,0x06,0x07,0x2a,0x86,0x48,0xce,0x3d,0x02,0x01,
  0x06,0x08,0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07,0x03,0x42,0x00,0x04,
]);
const SCOPE_KEYS = ["account","organization","incident","deployment","vehicle","authorityEpisode"] as const;
const CHALLENGE_KEYS = ["protocolVersion","audience","recoveryEpoch","scope","credentialId","publicKeySha256",
  "policyVersion","policyDocumentSha256","preciseAudienceSha256","issueOperationId","confirmOperationId",
  "challengeId","nonceBase64Url","issuedAtSeconds","expiresAtSeconds","expectedIncidentVersion",
  "expectedDeploymentVersion","expectedVehicleVersion","reservedGeneration"] as const;

function demand(ok: boolean, code: DeviceProofFailureCode = "INVALID_INPUT"): asserts ok {
  if (!ok) throw new DeviceProofFailure(code);
}
function record(value: unknown, keys: readonly string[]): Record<string, unknown> {
  demand(value !== null && typeof value === "object" && !Array.isArray(value));
  const proto = Object.getPrototypeOf(value);
  demand(proto === Object.prototype || proto === null);
  const descriptors = Object.getOwnPropertyDescriptors(value);
  demand(Object.keys(descriptors).length === keys.length &&
    keys.every(k => Object.prototype.hasOwnProperty.call(descriptors,k) && Object.prototype.hasOwnProperty.call(descriptors[k],"value")) &&
    Object.getOwnPropertySymbols(value).length === 0);
  return value as Record<string, unknown>;
}
function text(value: unknown, max: number): string {
  demand(typeof value === "string" && value.length <= max); return value;
}
function uuid(value: unknown): string {
  const s = text(value,36);
  demand(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(s) &&
    s !== "00000000-0000-0000-0000-000000000000"); return s;
}
function hash(value: unknown): string {
  const s = text(value,64); demand(/^[0-9a-f]{64}$/.test(s)); return s;
}
function integer(value: unknown, positive: boolean): string {
  const s = text(value,19);
  demand(/^(0|[1-9][0-9]*)$/.test(s));
  const n = BigInt(s); demand(n <= MAX_I64 && (!positive || n > 0n)); return s;
}
function audience(value: unknown): string {
  const s = text(value,128); demand(/^[A-Za-z0-9._:/-]+$/.test(s)); return s;
}
function policy(value: unknown): string {
  const s = text(value,64); demand(/^[A-Za-z0-9._-]+$/.test(s)); return s;
}
function scope(value: unknown): DeviceProofScopeV1 {
  const s = record(value,SCOPE_KEYS);
  return Object.freeze({account:uuid(s.account),organization:uuid(s.organization),incident:uuid(s.incident),
    deployment:uuid(s.deployment),vehicle:uuid(s.vehicle),authorityEpisode:uuid(s.authorityEpisode)});
}
function sameScope(a: DeviceProofScopeV1, b: DeviceProofScopeV1): boolean {
  return SCOPE_KEYS.every(k => a[k] === b[k]);
}
function nonce(value: unknown): string {
  demand(typeof value === "string" && value.length === 43,"INVALID_ENCODING");
  const s = value; demand(/^[A-Za-z0-9_-]{43}$/.test(s),"INVALID_ENCODING");
  try {
    const binary = atob(s.replace(/-/g,"+").replace(/_/g,"/")+"=");
    demand(binary.length === 32 && btoa(binary).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"") === s,"INVALID_ENCODING");
  } catch { throw new DeviceProofFailure("INVALID_ENCODING"); }
  return s;
}
function bytes(value: unknown, size?: number, code: DeviceProofFailureCode = "INVALID_ENCODING"): Uint8Array {
  demand(value instanceof Uint8Array,code);
  demand(size === undefined ? value.length <= 16_384 : value.length === size,code);
  const copy = new Uint8Array(value.length); copy.set(value); return copy;
}
function version(value: unknown): 1 {
  demand(value === 1,"UNSUPPORTED_PROTOCOL"); return 1;
}
function challenge(value: unknown): DeviceProofChallengeV1 {
  const c = record(value,CHALLENGE_KEYS);
  const result: DeviceProofChallengeV1 = Object.freeze({
    protocolVersion:version(c.protocolVersion),audience:audience(c.audience),recoveryEpoch:uuid(c.recoveryEpoch),scope:scope(c.scope),
    credentialId:uuid(c.credentialId),publicKeySha256:hash(c.publicKeySha256),policyVersion:policy(c.policyVersion),
    policyDocumentSha256:hash(c.policyDocumentSha256),preciseAudienceSha256:hash(c.preciseAudienceSha256),
    issueOperationId:uuid(c.issueOperationId),confirmOperationId:uuid(c.confirmOperationId),challengeId:uuid(c.challengeId),
    nonceBase64Url:nonce(c.nonceBase64Url),issuedAtSeconds:integer(c.issuedAtSeconds,false),
    expiresAtSeconds:integer(c.expiresAtSeconds,false),expectedIncidentVersion:integer(c.expectedIncidentVersion,true),
    expectedDeploymentVersion:integer(c.expectedDeploymentVersion,true),expectedVehicleVersion:integer(c.expectedVehicleVersion,true),
    reservedGeneration:integer(c.reservedGeneration,true),
  });
  demand(BigInt(result.issuedAtSeconds) <= MAX_I64-120n &&
    BigInt(result.expiresAtSeconds) === BigInt(result.issuedAtSeconds)+120n);
  demand(result.issueOperationId !== result.confirmOperationId);
  return result;
}
function encode(c: DeviceProofChallengeV1): Uint8Array {
  return new TextEncoder().encode([
    "GASILKO-VEHICLE-PHONE-BINDING-V1",c.audience,c.recoveryEpoch,"BIND_INACTIVE",
    c.scope.account,c.scope.organization,c.scope.incident,"REAL",c.scope.deployment,c.scope.vehicle,
    c.scope.authorityEpisode,"DRIVER",c.credentialId,c.publicKeySha256,c.policyVersion,
    c.policyDocumentSha256,c.preciseAudienceSha256,c.issueOperationId,c.confirmOperationId,c.challengeId,
    c.nonceBase64Url,c.issuedAtSeconds,c.expiresAtSeconds,c.expectedIncidentVersion,
    c.expectedDeploymentVersion,c.expectedVehicleVersion,c.reservedGeneration,
  ].join("\n")+"\n");
}
/** Construct exact Android v1 bytes. Never parses/trims a client transcript. */
export function encodeDeviceProofTranscriptV1(value: unknown): Uint8Array { return encode(challenge(value)); }

function credential(value: unknown): DeviceCredentialSnapshotV1 {
  const c = record(value,["protocolVersion","credentialId","scope","generation","lifecycleStatus","publicKeySha256","publicKeySpkiDer"]);
  const lifecycleStatus = c.lifecycleStatus;
  demand(lifecycleStatus === "INACTIVE" || lifecycleStatus === "REVOKED");
  const result: DeviceCredentialSnapshotV1 = {protocolVersion:version(c.protocolVersion),credentialId:uuid(c.credentialId),scope:scope(c.scope),
    generation:integer(c.generation,true),lifecycleStatus,publicKeySha256:hash(c.publicKeySha256),
    publicKeySpkiDer:bytes(c.publicKeySpkiDer,91,"INVALID_PUBLIC_KEY")};
  return Object.freeze(result);
}
function context(value: unknown): DeviceProofContextV1 {
  const c = record(value,["account","organization","scope","audience","recoveryEpoch","policyVersion","policyDocumentSha256",
    "preciseAudienceSha256","incidentVersion","deploymentVersion","vehicleVersion","generation","serverNowSeconds"]);
  return Object.freeze({account:uuid(c.account),organization:uuid(c.organization),scope:scope(c.scope),
    audience:audience(c.audience),recoveryEpoch:uuid(c.recoveryEpoch),policyVersion:policy(c.policyVersion),
    policyDocumentSha256:hash(c.policyDocumentSha256),preciseAudienceSha256:hash(c.preciseAudienceSha256),
    incidentVersion:integer(c.incidentVersion,true),deploymentVersion:integer(c.deploymentVersion,true),
    vehicleVersion:integer(c.vehicleVersion,true),generation:integer(c.generation,true),serverNowSeconds:integer(c.serverNowSeconds,false)});
}
function submission(value: unknown): DeviceProofSubmissionV1 {
  const p = record(value,["protocolVersion","credentialId","challengeId","issueOperationId","confirmOperationId",
    "signatureEncoding","signatureRaw","transcript"]);
  demand(p.signatureEncoding === "P1363_RAW64","INVALID_ENCODING");
  const result: DeviceProofSubmissionV1 = {protocolVersion:version(p.protocolVersion),credentialId:uuid(p.credentialId),
    challengeId:uuid(p.challengeId),issueOperationId:uuid(p.issueOperationId),confirmOperationId:uuid(p.confirmOperationId),
    signatureEncoding:"P1363_RAW64",signatureRaw:bytes(p.signatureRaw,64),transcript:bytes(p.transcript)};
  return Object.freeze(result);
}
function unsigned(bytes: Uint8Array): bigint {
  let result = 0n; for (const b of bytes) result = (result << 8n) | BigInt(b); return result;
}
function validateSpki(spki: Uint8Array): void {
  demand(spki.length === 91 && SPKI_PREFIX.every((b,i) => spki[i] === b),"INVALID_PUBLIC_KEY");
  const x = unsigned(spki.subarray(27,59)), y = unsigned(spki.subarray(59,91));
  demand(x < P && y < P && (y*y)%P === (((x*x)%P*x)%P+(P-3n)*x+B)%P,"INVALID_PUBLIC_KEY");
}
function validateSignature(raw: Uint8Array): void {
  const r = unsigned(raw.subarray(0,32)), s = unsigned(raw.subarray(32,64));
  demand(raw.length === 64 && r > 0n && r < N && s > 0n && s < N,"INVALID_ENCODING");
}
function equal(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let difference = 0; for (let i=0;i<a.length;i++) difference |= a[i]^b[i]; return difference === 0;
}
async function sha256(value: Uint8Array): Promise<string> {
  try {
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-256",value.buffer as ArrayBuffer));
    return Array.from(digest,b => b.toString(16).padStart(2,"0")).join("");
  } catch { throw new DeviceProofFailure("CRYPTO_UNAVAILABLE"); }
}
/**
 * Caller must supply a current authenticated/authorized context and registered
 * credential snapshot from trusted storage. This pure function CANNOT authenticate
 * those arguments, query current DRIVER/policy status, consume a nonce, or finalize.
 * Returned evidence MUST NEVER be accepted from an HTTP client as a success flag.
 */
export async function verifyDeviceProofV1(input: unknown): Promise<DeviceSignatureEvidenceV1> {
  const args = record(input,["challenge","credential","context","proof"]);
  // Snapshot every field/byte before the first await; caller mutations cannot retarget this verification.
  const c = challenge(args.challenge), k = credential(args.credential), expected = context(args.context), proof = submission(args.proof);
  demand(k.lifecycleStatus === "INACTIVE","CREDENTIAL_REVOKED");
  demand(expected.account === expected.scope.account && expected.organization === expected.scope.organization &&
    sameScope(c.scope,expected.scope) && sameScope(k.scope,expected.scope),"SCOPE_MISMATCH");
  demand(c.audience === expected.audience && c.recoveryEpoch === expected.recoveryEpoch &&
    c.policyVersion === expected.policyVersion && c.policyDocumentSha256 === expected.policyDocumentSha256 &&
    c.preciseAudienceSha256 === expected.preciseAudienceSha256 &&
    c.expectedIncidentVersion === expected.incidentVersion && c.expectedDeploymentVersion === expected.deploymentVersion &&
    c.expectedVehicleVersion === expected.vehicleVersion && c.reservedGeneration === expected.generation,"SCOPE_MISMATCH");
  demand(k.credentialId === c.credentialId && proof.credentialId === c.credentialId &&
    k.generation === c.reservedGeneration && k.publicKeySha256 === c.publicKeySha256,"CREDENTIAL_MISMATCH");
  demand(proof.challengeId === c.challengeId && proof.issueOperationId === c.issueOperationId &&
    proof.confirmOperationId === c.confirmOperationId,"SCOPE_MISMATCH");
  const now = BigInt(expected.serverNowSeconds);
  demand(now >= BigInt(c.issuedAtSeconds) && now < BigInt(c.expiresAtSeconds),"EXPIRED");
  const transcript = encode(c);
  demand(equal(transcript,proof.transcript),"TRANSCRIPT_MISMATCH");
  validateSpki(k.publicKeySpkiDer); validateSignature(proof.signatureRaw);
  const fingerprint = await sha256(k.publicKeySpkiDer);
  demand(fingerprint === k.publicKeySha256,"CREDENTIAL_MISMATCH");
  let key: CryptoKey;
  try {
    key = await crypto.subtle.importKey("spki",k.publicKeySpkiDer.buffer as ArrayBuffer,
      {name:"ECDSA",namedCurve:"P-256"},false,["verify"]);
  } catch (error) {
    throw new DeviceProofFailure(error instanceof DOMException && error.name === "NotSupportedError" ?
      "CRYPTO_UNAVAILABLE" : "INVALID_PUBLIC_KEY");
  }
  let valid: boolean;
  try {
    valid = await crypto.subtle.verify({name:"ECDSA",hash:"SHA-256"},key,
      proof.signatureRaw.buffer as ArrayBuffer,transcript.buffer as ArrayBuffer);
  } catch { throw new DeviceProofFailure("CRYPTO_UNAVAILABLE"); }
  demand(valid,"INVALID_SIGNATURE");
  const evidence: DeviceSignatureEvidenceV1 = {kind:"SIGNATURE_VALID_ONLY",protocolVersion:1,credentialId:c.credentialId,challengeId:c.challengeId,
    issueOperationId:c.issueOperationId,confirmOperationId:c.confirmOperationId,reservedGeneration:c.reservedGeneration,
    publicKeySha256:fingerprint,transcriptSha256:await sha256(transcript),signatureSha256:await sha256(proof.signatureRaw)};
  return Object.freeze(evidence);
}
