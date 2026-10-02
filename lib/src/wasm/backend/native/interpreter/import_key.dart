/// Encodes a Core import's original names without ambiguous separators.
///
/// Lengths count Dart UTF-16 code units, matching [String.length]. Each original
/// string remains unchanged, including empty names, Unicode and colons. This is
/// an internal map identity, not the binary format's UTF-8 name encoding.
String encodeImportKey(String module, String name) =>
    '${module.length}:$module${name.length}:$name';
