import 'dart:io';

/// A throwaway CA and a CA-signed `localhost` leaf generated per run with
/// `openssl` into a temp directory (never committed). Apple's trust evaluation
/// rejects a self-signed CA:TRUE certificate used directly as the server, so the
/// leaf is signed by a separate test CA. Null when `openssl` is unavailable.
class TlsFixture {
  TlsFixture._(this._dir, this.serverContext, this.clientContext);

  final Directory _dir;
  final SecurityContext serverContext;

  /// Trusts only the test CA.
  final SecurityContext clientContext;

  static Future<TlsFixture?> create() async {
    final dir = await Directory.systemTemp.createTemp('qirsh_tls_');
    final p = dir.path;
    File('$p/ext.cnf').writeAsStringSync(
        'subjectAltName=DNS:localhost,IP:127.0.0.1\n'
        'extendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n');
    final steps = [
      ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-subj',
        '/CN=QirshTestCA', '-keyout', '$p/ca.key', '-out', '$p/ca.pem'],
      ['req', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=localhost',
        '-keyout', '$p/key.pem', '-out', '$p/csr.pem'],
      ['x509', '-req', '-in', '$p/csr.pem', '-CA', '$p/ca.pem', '-CAkey',
        '$p/ca.key', '-CAcreateserial', '-days', '1', '-extfile',
        '$p/ext.cnf', '-out', '$p/cert.pem'],
    ];
    for (final args in steps) {
      final r = await Process.run('openssl', args)
          .catchError((Object _) => ProcessResult(0, 1, '', ''));
      if (r.exitCode != 0) {
        await dir.delete(recursive: true);
        return null;
      }
    }
    return TlsFixture._(
      dir,
      SecurityContext()
        ..useCertificateChain('$p/cert.pem')
        ..usePrivateKey('$p/key.pem'),
      SecurityContext()..setTrustedCertificates('$p/ca.pem'),
    );
  }

  Future<void> dispose() => _dir.delete(recursive: true);
}
