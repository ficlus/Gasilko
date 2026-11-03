/**
 * M15A.3 INTERNAL primitives, not an HTTP handler/JWT verifier/enrollment service.
 * No runtime caller, DB client, policy approval or FINALIZE exists.
 * Only a future trusted adapter may supply policy/context and claimed DB snapshots.
 */
import {
  encodeDeviceProofTranscriptV1, verifyDeviceProofV1,
  type DeviceProofChallengeV1, type DeviceProofSubmissionV1, type DeviceSignatureEvidenceV1,
} from "./deviceProofV1.ts";

export class DeviceProofLifecycleFailure extends Error {
  constructor(readonly code: "INVALID_INPUT" | "CLAIM_EXPIRED" | "OPERATION_REUSED" | "CRYPTO_UNAVAILABLE") {
    super(code); this.name = "DeviceProofLifecycleFailure";
  }
}
function requireValue(ok: boolean, code: DeviceProofLifecycleFailure["code"] = "INVALID_INPUT"): asserts ok {
  if (!ok) throw new DeviceProofLifecycleFailure(code);
}
function data(value: unknown, keys: readonly string[]): Record<string, unknown> {
  requireValue(value !== null && typeof value === "object" && !Array.isArray(value));
  const proto = Object.getPrototypeOf(value), fields = Object.getOwnPropertyDescriptors(value);
  requireValue((proto === Object.prototype || proto === null) && Object.getOwnPropertySymbols(value).length === 0 &&
    Object.keys(fields).length === keys.length && keys.every(k => fields[k] && "value" in fields[k]));
  return value as Record<string, unknown>;
}
const hashPattern = /^[0-9a-f]{64}$/;
const uuidPattern = /^(?!00000000-0000-0000-0000-000000000000$)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
async function digest(bytes: Uint8Array): Promise<string> {
  try {
    return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256",bytes.buffer as ArrayBuffer)),
      b => b.toString(16).padStart(2,"0")).join("");
  } catch { throw new DeviceProofLifecycleFailure("CRYPTO_UNAVAILABLE"); }
}

type TrustedChallengeContext = Omit<DeviceProofChallengeV1,
  "challengeId" | "nonceBase64Url" | "issuedAtSeconds" | "expiresAtSeconds">;
const CONTEXT_KEYS = ["protocolVersion","audience","recoveryEpoch","scope","credentialId","publicKeySha256",
  "policyVersion","policyDocumentSha256","preciseAudienceSha256","issueOperationId","confirmOperationId",
  "expectedIncidentVersion","expectedDeploymentVersion","expectedVehicleVersion","reservedGeneration"] as const;

/**
 * In-memory construction ONLY. It does not authenticate the context, issue/persist
 * a challenge, reserve operation IDs, or establish policy approval. No default/dummy
 * policy/audience/recovery epoch. Public ISSUE is BLOCKED_BY_POLICY.
 * Retries must recover the stored original, NEVER call this constructor again.
 */
export async function constructDeviceChallengeV1(trustedContext: TrustedChallengeContext) {
  const input = data(trustedContext,CONTEXT_KEYS);
  // Clone before the first await; no caller-owned context can be retargeted later.
  data(input.scope,["account","organization","incident","deployment","vehicle","authorityEpisode"]);
  const context: TrustedChallengeContext = {...trustedContext,scope:{...trustedContext.scope}};
  let id: string, nonce: Uint8Array;
  try { id = crypto.randomUUID(); nonce = crypto.getRandomValues(new Uint8Array(32)); }
  catch { throw new DeviceProofLifecycleFailure("CRYPTO_UNAVAILABLE"); }
  const now = BigInt(Math.floor(Date.now()/1000));
  const challenge: DeviceProofChallengeV1 = {...context,challengeId:id,
    nonceBase64Url:btoa(String.fromCharCode(...nonce)).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,""),
    issuedAtSeconds:now.toString(),expiresAtSeconds:(now+120n).toString()};
  // Existing v1 encoder validates every field and fixes all 27 lines/trailing LF.
  const transcript = encodeDeviceProofTranscriptV1(challenge);
  const transcriptSha256 = await digest(transcript);
  Object.freeze(challenge.scope); Object.freeze(challenge);
  return Object.freeze({challenge,transcript,transcriptSha256});
}

/**
 * Input shape is the JSON returned by private.claim_vehicle_device_proof.
 * Types/names cannot authenticate its provenance. NEVER accept this from HTTP.
 * No new crypto parser: canonical SPKI/point/raw64/transcript checks stay in v1.
 */
export async function verifyClaimedDeviceProofV1(snapshot: unknown, proof: DeviceProofSubmissionV1):
 Promise<Readonly<{claimId: string; claimExpiresAtSeconds: string; evidence: DeviceSignatureEvidenceV1}>> {
  const row = data(snapshot,["state","claimId","claimExpiresAtSeconds","transcriptSha256","signatureSha256","challenge","context","credential"]);
  requireValue(row.state === "CLAIMED" && typeof row.claimId === "string" && uuidPattern.test(row.claimId));
  requireValue(typeof row.claimExpiresAtSeconds === "string" && /^(0|[1-9][0-9]{0,18})$/.test(row.claimExpiresAtSeconds));
  requireValue(typeof row.transcriptSha256 === "string" && hashPattern.test(row.transcriptSha256) &&
    typeof row.signatureSha256 === "string" && hashPattern.test(row.signatureSha256));
  const claimId = row.claimId, claimExpiresAtSeconds = row.claimExpiresAtSeconds;
  const transcriptHash = row.transcriptSha256, signatureHash = row.signatureSha256;
  const credential = data(row.credential,["protocolVersion","credentialId","scope","generation","lifecycleStatus","publicKeySha256","publicKeySpkiDerHex"]);
  requireValue(typeof credential.publicKeySpkiDerHex === "string" && /^[0-9a-f]{182}$/.test(credential.publicKeySpkiDerHex));
  const spki = Uint8Array.from(credential.publicKeySpkiDerHex.match(/../g)!,h => parseInt(h,16));
  const fields = {...credential};
  delete fields.publicKeySpkiDerHex;
  // Capture lease clock, but v1 is still responsible for validating exact context.
  const clock = Object.getOwnPropertyDescriptor(row.context ?? {},"serverNowSeconds");
  requireValue(!!clock && "value" in clock && typeof clock.value === "string" && /^(0|[1-9][0-9]{0,18})$/.test(clock.value));
  requireValue(BigInt(clock.value) < BigInt(claimExpiresAtSeconds),"CLAIM_EXPIRED");
  // v1 snapshots/validates all objects and proof buffers synchronously before await.
  const evidence = await verifyDeviceProofV1({challenge:row.challenge,context:row.context,
    credential:{...fields,publicKeySpkiDer:spki},proof});
  requireValue(evidence.transcriptSha256 === transcriptHash && evidence.signatureSha256 === signatureHash,"OPERATION_REUSED");
  // Still SIGNATURE_VALID_ONLY. Lease/current authority/revocation must be checked
  // AGAIN in a privileged TX-B; this module cannot commit or renew anything.
  return Object.freeze({claimId,claimExpiresAtSeconds,evidence});
}
