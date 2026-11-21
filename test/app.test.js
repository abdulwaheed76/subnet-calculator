const request = require('supertest');
const app = require('../src/app');

describe('API', () => {
  test('GET / serves the web page', async () => {
    const res = await request(app).get('/');
    expect(res.status).toBe(200);
    expect(res.type).toBe('text/html');
  });

  test('GET /health reports status and version', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({ status: 'ok', version: expect.any(String) });
  });

  test('POST /api/subnet returns the calculation', async () => {
    const res = await request(app).post('/api/subnet').send({ cidr: '10.0.0.0/24' });
    expect(res.status).toBe(200);
    expect(res.body.usableHosts).toBe(254);
  });

  test('POST /api/subnet with bad CIDR returns 400', async () => {
    const res = await request(app).post('/api/subnet').send({ cidr: '999.0.0.0/24' });
    expect(res.status).toBe(400);
    expect(res.body.error).toMatch(/Invalid IPv4/);
  });

  test('POST /api/subnet with no body returns 400', async () => {
    const res = await request(app).post('/api/subnet');
    expect(res.status).toBe(400);
  });

  test('malformed JSON returns 400', async () => {
    const res = await request(app)
      .post('/api/subnet')
      .set('Content-Type', 'application/json')
      .send('{bad json');
    expect(res.status).toBe(400);
  });

  test('unknown route returns 404', async () => {
    const res = await request(app).get('/nope');
    expect(res.status).toBe(404);
    expect(res.body.error).toBe('Not found');
  });
});
