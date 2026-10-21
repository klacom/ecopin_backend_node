import {jest} from '@jest/globals';
const from = jest.fn();
jest.unstable_mockModule('../src/config/supabase.config.js', () => ({supabaseAdmin:{from}}));
const {getStaffReports,getReportsByClusterId} = await import('../src/controllers/report-read.controller.js');
const id = '11111111-1111-1111-1111-111111111111';
const query = () => ({select:jest.fn().mockReturnThis(), eq:jest.fn().mockReturnThis(), in:jest.fn().mockReturnThis(),
  order:jest.fn().mockReturnThis(), range:jest.fn().mockResolvedValue({data:[],error:null})});
const response = () => ({status:jest.fn().mockReturnThis(), json:jest.fn(),set:jest.fn()});
beforeEach(() => jest.clearAllMocks());
test('offline ID batches constrain the report query instead of downloading the first 200 reports', async () => {
  const q = query(); from.mockReturnValue(q); const res = response(); const next = jest.fn();
  await getStaffReports({query:{ids:id,limit:'100'},user:{role:'field_crew'}},res,next);
  expect(q.in).toHaveBeenCalledWith('id',[id]);
  expect(q.range).toHaveBeenCalledWith(0,100);
  expect(next).not.toHaveBeenCalled();
  expect(res.json).toHaveBeenCalledWith([]);
});
test.each(['', 'invalid', Array(101).fill(id).map((_,i)=>`00000000-0000-0000-0000-${String(i).padStart(12,'0')}`).join(',')])('rejects malformed or oversized ID input', async ids => {
  const q = query(); from.mockReturnValue(q); const res = response();
  await getStaffReports({query:{ids}},res,jest.fn());
  expect(res.status).toHaveBeenCalledWith(400);
  expect(q.range).not.toHaveBeenCalled();
});

test('authenticated crew cluster preparation uses operational records rather than only the public subset', async () => {
  const q = query(); from.mockReturnValue(q); const res = response();
  await getReportsByClusterId({query:{},params:{clusterId:id},user:{role:'field_crew'}},res,jest.fn());
  expect(from).toHaveBeenCalledWith('reports_view');
  expect(q.eq).toHaveBeenCalledWith('cluster_id',id);
});
