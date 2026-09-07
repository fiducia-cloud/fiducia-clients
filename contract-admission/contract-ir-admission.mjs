import { createHash } from 'node:crypto';

export const CONTRACT_IR_SCHEMA = 'ores.typespec-json-schema-validator.contract-ir/v1';
export const PARITY_REPORT_SCHEMA = 'ores.typespec-json-schema-validator.report/v1';
const HEX_256 = /^[a-f0-9]{64}$/u;
const SET_LIKE_ARRAY_KEYS = new Set(['allOf', 'anyOf', 'enum', 'oneOf', 'required', 'type']);

function fail(message) { throw new Error(`contract-ir admission rejected: ${message}`); }
function requireCondition(condition, message) { if (!condition) fail(message); }
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function canonicalize(value, parentKey = '') {
  if (Array.isArray(value)) {
    const items = value.map((item) => canonicalize(item));
    if (!SET_LIKE_ARRAY_KEYS.has(parentKey)) return items;
    const byEncoding = new Map(items.map((item) => [JSON.stringify(item), item]));
    return [...byEncoding.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([, item]) => item);
  }
  if (!isObject(value)) return value;
  const result = {};
  for (const key of Object.keys(value).sort()) result[key] = canonicalize(value[key], key);
  return result;
}
export function canonicalStringify(value) { return JSON.stringify(canonicalize(value)); }
export function sha256Json(value) { return createHash('sha256').update(canonicalStringify(value)).digest('hex'); }
function requireDigest(value, label) { requireCondition(typeof value === 'string' && HEX_256.test(value), `${label} must be a lowercase SHA-256 digest`); return value; }
function expectedDigest(expectedInputs, key) { requireCondition(isObject(expectedInputs), 'expectedInputs is required'); return requireDigest(expectedInputs[key], `expectedInputs.${key}`); }

export function verifyContractIrAdmission({ contractIr, parityReport, expectedInputs, requireComplete = false }) {
  requireCondition(isObject(contractIr), 'contractIr must be an object');
  requireCondition(isObject(parityReport), 'parityReport must be an object');
  requireCondition(contractIr.schema === CONTRACT_IR_SCHEMA, `unexpected Contract IR schema ${String(contractIr.schema)}`);
  requireCondition(contractIr.status === 'passed', 'Contract IR status must be passed');
  requireCondition(contractIr.admissible === true, 'Contract IR must be admissible');
  requireCondition(contractIr.role === 'downstream-derived-parity-artifact', 'Contract IR role is invalid');
  requireCondition(contractIr.editableAuthority === false, 'Contract IR must not be an editable authority');
  requireCondition(contractIr.authorities?.typespec === 'independently-authored', 'TypeSpec must remain independently authored');
  requireCondition(contractIr.authorities?.jsonSchema === 'independently-authored', 'JSON Schema must remain independently authored');
  requireCondition(contractIr.authorities?.generatedJsonSchema === 'comparison-evidence-only', 'generated JSON Schema must remain comparison evidence only');
  requireCondition(contractIr.authorities?.precedence === 'none', 'peer authorities must have no precedence');
  requireCondition(parityReport.schema === PARITY_REPORT_SCHEMA, `unexpected parity report schema ${String(parityReport.schema)}`);
  requireCondition(parityReport.status === 'passed', 'parity report status must be passed');
  requireCondition(parityReport.zeroUnexplainedFindings === true, 'parity report must have zero unexplained findings');
  requireCondition(Array.isArray(parityReport.findings) && parityReport.findings.length === 0, 'parity report findings must be empty');
  requireDigest(parityReport.runId, 'parityReport.runId');
  const receipt = contractIr.admission?.receipt;
  requireCondition(isObject(receipt), 'Contract IR receipt is missing');
  requireCondition(receipt.schema === parityReport.schema, 'receipt schema does not match parity report');
  requireCondition(receipt.runId === parityReport.runId, 'receipt runId does not match parity report');
  requireCondition(receipt.status === 'passed', 'receipt status must be passed');
  requireCondition(receipt.zeroUnexplainedFindings === true, 'receipt must bind zero unexplained findings');
  requireCondition(receipt.digest === sha256Json(parityReport), 'receipt digest does not match the supplied parity report');
  const suppliedIrId = requireDigest(contractIr.irId, 'contractIr.irId');
  const irBody = { ...contractIr }; delete irBody.irId;
  requireCondition(suppliedIrId === sha256Json(irBody), 'Contract IR self digest does not match its body');
  for (const [reportKey, provenanceKey, expectedKey] of [['typespec','typespec','typespec'],['authoredJsonSchema','authoredJsonSchema','authoredJsonSchema'],['generatedJsonSchema','generatedJsonSchema','generatedJsonSchema']]) {
    const expected = expectedDigest(expectedInputs, expectedKey);
    const reportDigest = requireDigest(parityReport.inputs?.[reportKey]?.digest, `parityReport.inputs.${reportKey}.digest`);
    const provenanceDigest = requireDigest(contractIr.provenance?.[provenanceKey]?.digest, `contractIr.provenance.${provenanceKey}.digest`);
    requireCondition(reportDigest === expected, `${reportKey} parity-report digest is stale for this checkout`);
    requireCondition(provenanceDigest === expected, `${provenanceKey} Contract IR digest is stale for this checkout`);
  }
  if (requireComplete) requireCondition(contractIr.admission?.scope?.complete === true, 'consumer requires a complete Contract IR scope');
  requireCondition(Array.isArray(contractIr.declarations), 'Contract IR declarations are missing');
  for (const declaration of contractIr.declarations) {
    requireCondition(isObject(declaration), 'Contract IR declaration must be an object');
    requireDigest(declaration.assertionDigest, `declaration ${String(declaration.id)} assertionDigest`);
    requireCondition(declaration.assertionDigest === sha256Json(declaration.assertionSchema), `declaration ${String(declaration.id)} assertion digest is invalid`);
    requireCondition(declaration.lanes?.typespecGeneratedJsonSchema?.role === 'comparison-evidence-only', `declaration ${String(declaration.id)} generated lane role is invalid`);
    requireCondition(declaration.lanes?.authoredJsonSchema?.role === 'independently-authored-authority', `declaration ${String(declaration.id)} authored lane role is invalid`);
  }
  return Object.freeze({ admitted: true, irId: contractIr.irId, runId: parityReport.runId, inputs: Object.freeze({ ...expectedInputs }) });
}
