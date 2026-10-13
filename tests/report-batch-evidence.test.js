import { jest } from '@jest/globals';

const mockCloudinaryResources = jest.fn();
jest.unstable_mockModule('cloudinary', () => ({
  v2: {
    config: jest.fn(),
    api: {
      resources: mockCloudinaryResources
    }
  }
}));

const mockReadReportForViewer = jest.fn();
const mockCanReadReportEvidence = jest.fn();

jest.unstable_mockModule('../src/services/report-access.service.js', () => ({
  readReportForViewer: mockReadReportForViewer,
  canReadReportEvidence: mockCanReadReportEvidence,
  PUBLIC_REPORT_FIELDS: 'id,title,description',
  reportPage: jest.fn(() => ({ limit: 100, offset: 0 }))
}));

const { getBatchReportEvidence } = await import('../src/controllers/report.controller.js');

function response() {
  return {
    statusCode: 200,
    status(code) { this.statusCode = code; return this; },
    json(data) { this.body = data; return this; }
  };
}

describe('POST /api/reports/batch-evidence', () => {
  beforeEach(() => {
    mockCloudinaryResources.mockReset();
    mockReadReportForViewer.mockReset();
    mockCanReadReportEvidence.mockReset();
  });

  test('returns empty object when no reportIds are passed', async () => {
    const res = response();
    await getBatchReportEvidence({ body: { reportIds: [] } }, res, jest.fn());
    expect(res.statusCode).toBe(200);
    expect(res.body).toEqual({});
  });

  test('batches evidence for authorized reports into a dictionary', async () => {
    mockReadReportForViewer.mockImplementation(async (supabase, id) => ({
      report: { id, location_precision: 'exact' }
    }));
    mockCanReadReportEvidence.mockReturnValue(true);

    mockCloudinaryResources.mockImplementation(async ({ prefix, resource_type }) => {
      if (prefix === 'report_evidence/rep-1' && resource_type === 'image') {
        return {
          resources: [
            { public_id: 'report_evidence/rep-1/photo1', secure_url: 'https://cdn/rep1.jpg', bytes: 1024, created_at: '2026-10-13', format: 'jpg', resource_type: 'image' }
          ]
        };
      }
      return { resources: [] };
    });

    const req = {
      body: { reportIds: ['rep-1', 'rep-2'] },
      user: { id: 'officer-1', role: 'officer' }
    };
    const res = response();

    await getBatchReportEvidence(req, res, jest.fn());

    expect(res.statusCode).toBe(200);
    expect(res.body).toHaveProperty('rep-1');
    expect(res.body).toHaveProperty('rep-2');
    expect(res.body['rep-1']).toHaveLength(1);
    expect(res.body['rep-1'][0]).toMatchObject({
      name: 'photo1.jpg',
      url: 'https://cdn/rep1.jpg',
      resource_type: 'image'
    });
    expect(res.body['rep-2']).toEqual([]);
  });

  test('omits evidence when access check is denied', async () => {
    mockReadReportForViewer.mockResolvedValue({ report: { id: 'unauthorized-rep' } });
    mockCanReadReportEvidence.mockReturnValue(false); // Denied

    const req = {
      body: { reportIds: ['unauthorized-rep'] },
      user: { id: 'stranger', role: 'citizen' }
    };
    const res = response();

    await getBatchReportEvidence(req, res, jest.fn());

    expect(res.statusCode).toBe(200);
    expect(res.body['unauthorized-rep']).toEqual([]);
    expect(mockCloudinaryResources).not.toHaveBeenCalled();
  });
});
