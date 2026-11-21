class ValidationError extends Error {
  constructor(message) {
    super(message);
    this.status = 400;
  }
}

function ipToInt(ip) {
  const octets = ip.split('.');
  if (octets.length !== 4 || !octets.every((o) => /^\d{1,3}$/.test(o) && Number(o) <= 255)) {
    throw new ValidationError(`Invalid IPv4 address: ${ip}`);
  }
  // Multiply instead of << so values above 2^31 don't turn negative.
  return octets.reduce((acc, o) => acc * 256 + Number(o), 0);
}

function intToIp(n) {
  return [n >>> 24, (n >>> 16) & 255, (n >>> 8) & 255, n & 255].join('.');
}

function calculateSubnet(cidr) {
  if (typeof cidr !== 'string') {
    throw new ValidationError('Body must include "cidr" as a string, e.g. "10.0.0.0/24"');
  }
  const match = /^([\d.]+)\/(\d{1,2})$/.exec(cidr.trim());
  if (!match || Number(match[2]) > 32) {
    throw new ValidationError(`Invalid CIDR: ${cidr}`);
  }

  const prefix = Number(match[2]);
  const ip = ipToInt(match[1]);
  // JS shifts are mod 32, so /0 needs its own case.
  const mask = prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0;
  const network = (ip & mask) >>> 0;
  const broadcast = (network | ~mask) >>> 0;
  const total = 2 ** (32 - prefix);

  // /31 (point-to-point, RFC 3021) and /32 have no network/broadcast to reserve.
  const reserved = prefix >= 31 ? 0 : 1;

  return {
    cidr: `${intToIp(network)}/${prefix}`,
    networkAddress: intToIp(network),
    broadcastAddress: intToIp(broadcast),
    subnetMask: intToIp(mask),
    firstHost: intToIp(network + reserved),
    lastHost: intToIp(broadcast - reserved),
    totalAddresses: total,
    usableHosts: total - 2 * reserved,
  };
}

module.exports = { calculateSubnet, ValidationError };
