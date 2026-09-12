import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createFiduciaMetricViews} from '../claritas.ts';
const sample = (id, value) => ({ nodeId: id, region: 'group', metric: 'request_latency_ms', unit: 'ms', at: 0, value });
const window = {start: 0, end: 20, bucketMs: 10, minEntities: 2};
function port() { return {cohortTrends: (rows, window) => [{rows, window}], individualTrend: (rows,id,window) => ({rows,id,window}), trendSvg: () => '<svg/>'}; }
test('adapter exports immutable local entry points', () => assert.ok(Object.isFrozen(createFiduciaMetricViews(port()))));
test('projection preserves exact identity and excludes private metadata', () => {
  const rows=[{...sample('same@1',0),secret:'never-forward',rawBody:'private'},sample('same@2',null)];
  const before=JSON.stringify(rows); const result=createFiduciaMetricViews(port()).cohorts(rows,'request_latency_ms',window);
  assert.deepEqual(result[0].series.rows,[{entityId:'same@1',cohortId:'group',at:0,value:0},{entityId:'same@2',cohortId:'group',at:0,value:null}]);
  assert.equal(JSON.stringify(rows),before);
});
test('individual projection uses the selected identifier and unchanged window', () => {
  const result=createFiduciaMetricViews(port()).individual([sample('a',1)],'request_latency_ms','a',window);
  assert.equal(result.series.id,'a'); assert.equal(result.series.window,window);
});
test('mixed metrics, units and invalid values fail with generic errors', () => {
  for(const patch of [{unit:'wrong'},{metric:'wrong'},{value:NaN},{value:Infinity},{value:'1'}])
    assert.throws(()=>createFiduciaMetricViews(port()).cohorts([{...sample('a',1),...patch}],'request_latency_ms',window),{message:'Invalid metric projection'});
});
test('incomplete SDK and unbounded inputs rejected', () => {
  assert.throws(()=>createFiduciaMetricViews({}),TypeError);
  assert.throws(()=>createFiduciaMetricViews(port()).cohorts(Array(50001).fill(sample('a',1)),'request_latency_ms',window),TypeError);
  assert.throws(()=>createFiduciaMetricViews(port()).cohorts([],'constructor',window),TypeError);
});
test('SDK failures propagate instead of substituting demo data', () => {
  const error=new Error('upstream failure'); const sdk={...port(),cohortTrends:()=>{throw error}};
  assert.throws(()=>createFiduciaMetricViews(sdk).cohorts([],'request_latency_ms',window),error);
});
