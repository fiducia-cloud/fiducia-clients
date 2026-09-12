import {test} from 'node:test';
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
import {createFiduciaMetricViews} from '../claritas.ts';
// Explicit local built artifacts. Missing dependencies fail; this test never skips or fetches.
if (!process.env.CLARITAS_CORE_MODULE || !process.env.CLARITAS_CLIENT_MODULE)
  throw new Error('Both pinned Claritas module paths are required');
const core=await import(pathToFileURL(process.env.CLARITAS_CORE_MODULE).href);
const sdk=await import(pathToFileURL(process.env.CLARITAS_CLIENT_MODULE).href);
const views=createFiduciaMetricViews(sdk.createLocalVisualizationClient(core.createVisualizationSdk()));
const sample=(id,value,at=0)=>({nodeId:id,region:'group',metric:'request_latency_ms',unit:'ms',at,value});
const window={start:0,end:30,bucketMs:10,minEntities:2};
test('real Claritas core and SDK render entity-balanced cohort data',()=>{
  const prior=globalThis.fetch;globalThis.fetch=()=>{throw Error('unexpected network')};
  try {
    const [result]=views.cohorts([sample('a',0),sample('a',0,1),sample('b',10)],'request_latency_ms',window);
    assert.equal(result.series.points[0].value,5);assert.equal(result.series.points[0].entities,2);
    assert.ok(result.svg.startsWith('<svg'));assert.ok(!/NaN|Infinity/.test(result.svg));
    assert.equal(result.series.points[1].state,'missing');
  } finally {globalThis.fetch=prior;}
});
test('real core preserves individual zero and small-cohort suppression',()=>{
  assert.equal(views.individual([sample('a',0)],'request_latency_ms','a',window).series.points[0].value,0);
  const point=views.cohorts([sample('a',1)],'request_latency_ms',window)[0].series.points[0];
  assert.deepEqual([point.state,point.value,point.entities],['suppressed',null,null]);
});
