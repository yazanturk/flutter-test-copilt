/// Redacts likely-sensitive values before they reach logs, reports or an
/// agent. Matching itself always runs on raw values; only *output* is
/// sanitized.
///
/// Obscured text fields (passwords) are never captured in the first place –
/// see `UiDiscovery`.
class Sanitizer {
  const Sanitizer({this.redactEmails = true, this.redactLongNumbers = true, this.secrets = const <String>{}});

  /// A sanitizer that passes everything through. Only use it locally.
  const Sanitizer.none() : redactEmails = false, redactLongNumbers = false, secrets = const <String>{};

  static const String redacted = '<redacted>';

  Sanitizer withSecrets(Iterable<String> more) => Sanitizer(
      redactEmails: redactEmails, redactLongNumbers: redactLongNumbers, secrets: {...secrets, ...more});

  final bool redactEmails;

  /// Sequences of 6+ digits: phone, card, account and ID numbers.
  final bool redactLongNumbers;

  /// Exact values to always redact, e.g. test passwords or tokens.
  final Set<String> secrets;

  static final RegExp _email = RegExp(r'[\w.+-]+@[\w-]+(\.[\w-]+)+');
  static final RegExp _longNumber = RegExp(r'\d[\d \-]{4,}\d');

  String text(String value) {
    var result = value;
    for (final secret in secrets) {
      if (secret.isNotEmpty) result = result.replaceAll(secret, redacted);
    }
    if (redactEmails) result = result.replaceAll(_email, '<email>');
    if (redactLongNumbers) {
      result = result.replaceAllMapped(_longNumber, (m) {
        final digits = m[0]!.replaceAll(RegExp(r'\D'), '');
        return digits.length >= 6 ? '<number>' : m[0]!;
      });
    }
    return result;
  }
}
