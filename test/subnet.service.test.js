const { calculateSubnet, ValidationError } = require('../src/services/subnet.service');

describe('calculateSubnet', () => {
  test('/24 network', () => {
    expect(calculateSubnet('192.168.1.0/24')).toEqual({
      cidr: '192.168.1.0/24',
      networkAddress: '192.168.1.0',
      broadcastAddress: '192.168.1.255',
      subnetMask: '255.255.255.0',
      firstHost: '192.168.1.1',
      lastHost: '192.168.1.254',
      totalAddresses: 256,
      usableHosts: 254,
    });
  });

  test('host bits are cleared to find the network', () => {
    const r = calculateSubnet('10.0.0.77/26');
    expect(r.cidr).toBe('10.0.0.64/26');
    expect(r.broadcastAddress).toBe('10.0.0.127');
  });

  test('/32 is a single host', () => {
    const r = calculateSubnet('8.8.8.8/32');
    expect(r).toMatchObject({ firstHost: '8.8.8.8', lastHost: '8.8.8.8', usableHosts: 1 });
  });

  test('/31 has two usable hosts (RFC 3021)', () => {
    const r = calculateSubnet('10.0.0.0/31');
    expect(r).toMatchObject({ firstHost: '10.0.0.0', lastHost: '10.0.0.1', usableHosts: 2 });
  });

  test('/0 covers the whole IPv4 range', () => {
    const r = calculateSubnet('1.2.3.4/0');
    expect(r).toMatchObject({
      networkAddress: '0.0.0.0',
      broadcastAddress: '255.255.255.255',
      subnetMask: '0.0.0.0',
      totalAddresses: 2 ** 32,
    });
  });

  test('high addresses stay positive', () => {
    expect(calculateSubnet('255.255.255.0/24').networkAddress).toBe('255.255.255.0');
  });

  test.each([
    ['10.0.0.0'],
    ['10.0.0.256/24'],
    ['10.0.0.0/33'],
    ['10.0.0/24'],
    ['10.0.0.0.0/24'],
    ['abc'],
    [''],
    [123],
    [undefined],
  ])('rejects %p', (input) => {
    expect(() => calculateSubnet(input)).toThrow(ValidationError);
  });
});
