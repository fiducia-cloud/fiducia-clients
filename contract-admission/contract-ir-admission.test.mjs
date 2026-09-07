import assert from 'node:assert/strict';
import test from 'node:test';
import { sha256Json, verifyContractIrAdmission } from './contract-ir-admission.mjs';
const hex = (c) => c.repeat(64);
function fixture() {
  const expectedInputs = { typespec: hex('a'), authoredJsonSchema: hex('b'), generatedJsonSchema: hex('c') };
  const parityReport = { schema:'ores.typespec-json-schema-validator.report/v1', runId:hex('d'), status:'passed', zeroUnexplainedFindings:true, findings:[], inputs:{ typespec:{digest:expectedInputs.typespec}, authoredJsonSchema:{digest:expectedInputs.authoredJsonSchema}, generatedJsonSchema:{digest:expectedInputs.generatedJsonSchema} } };
  const assertionSchema = { type:'object', required:['id'], properties:{ id:{type:'string'} } };
  const body = { schema:'ores.typespec-json-schema-validator.contract-ir/v1', status:'passed', admissible:true, role:'downstream-derived-parity-artifact', editableAuthority:false, authorities:{ typespec:'independently-authored', jsonSchema:'independently-authored', generatedJsonSchema:'comparison-evidence-only', precedence:'none' }, admission:{ receipt:{ schema:parityReport.schema, runId:parityReport.runId, digest:sha256Json(parityReport), status:'passed', zeroUnexplainedFindings:true }, scope:{complete:true} }, provenance:{ typespec:{digest:expectedInputs.typespec}, authoredJsonSchema:{digest:expectedInputs.authoredJsonSchema}, generatedJsonSchema:{digest:expectedInputs.generatedJsonSchema} }, declarations:[{ id:'Example.User', assertionSchema, assertionDigest:sha256Json(assertionSchema), lanes:{ typespecGeneratedJsonSchema:{role:'comparison-evidence-only'}, authoredJsonSchema:{role:'independently-authored-authority'} } }] };
  return { contractIr:{...body, irId:sha256Json(body)}, parityReport, expectedInputs };
}
test('admits exact peer-authority parity evidence',()=>assert.equal(verifyContractIrAdmission({...fixture(),requireComplete:true}).admitted,true));
test('rejects stale checkout digest',()=>{const v=fixture();v.expectedInputs.typespec=hex('e');assert.throws(()=>verifyContractIrAdmission(v),/stale for this checkout/);});
test('rejects tampered parity evidence',()=>{const v=fixture();v.parityReport.zeroUnexplainedFindings=false;assert.throws(()=>verifyContractIrAdmission(v),/zero unexplained findings/);});
test('rejects promoted editable authority',()=>{const v=fixture();v.contractIr.editableAuthority=true;assert.throws(()=>verifyContractIrAdmission(v),/must not be an editable authority/);});
