import 'dart:io';

/// Only concrete loopback or RFC 1918 IPv4 literals are valid Jam endpoints.
bool isJamAddress(InternetAddress address) {
  if (address.type != InternetAddressType.IPv4) return false;
  final b = address.rawAddress;
  return b[0] == 127 ||
      b[0] == 10 ||
      b[0] == 172 && b[1] >= 16 && b[1] <= 31 ||
      b[0] == 192 && b[1] == 168;
}

InternetAddress validateJamAddress(InternetAddress address) {
  if (!isJamAddress(address)) throw ArgumentError.value(address, 'address');
  return address;
}
