/// Internal WIT document boundary model for future Preview2/Preview3 adapters.
///
/// This parser intentionally stops at package/interface/world boundaries. It
/// gives adapter generation a structured, diagnosable input without claiming
/// full WIT semantic coverage or public WASI component support.
final class WASIComponentWitDocument {
  /// Creates a parsed WIT document from already-normalized declarations.
  WASIComponentWitDocument({
    required List<WASIComponentWitInterface> interfaces,
    required List<WASIComponentWitWorld> worlds,
    this.package,
  }) : interfaces = List<WASIComponentWitInterface>.unmodifiable(interfaces),
       worlds = List<WASIComponentWitWorld>.unmodifiable(worlds);

  /// Parses [source] into the internal package/interface/world boundary model.
  factory WASIComponentWitDocument.parse(
    String source, {
    String sourceName = '<wit>',
  }) {
    return _WitParser(source, sourceName).parse();
  }

  /// Optional top-level WIT package declaration.
  final WASIComponentWitPackage? package;

  /// Top-level interfaces declared by this document.
  final List<WASIComponentWitInterface> interfaces;

  /// Top-level worlds declared by this document.
  final List<WASIComponentWitWorld> worlds;

  /// Returns the interface named [name], if this document declares one.
  WASIComponentWitInterface? interfaceNamed(String name) {
    for (final interface in interfaces) {
      if (interface.name == name) {
        return interface;
      }
    }
    return null;
  }

  /// Returns the world named [name], if this document declares one.
  WASIComponentWitWorld? worldNamed(String name) {
    for (final world in worlds) {
      if (world.name == name) {
        return world;
      }
    }
    return null;
  }
}

/// Top-level `package namespace:name@version;` declaration.
final class WASIComponentWitPackage {
  /// Creates a package declaration boundary.
  const WASIComponentWitPackage({
    required this.namespace,
    required this.name,
    required this.span,
    this.version,
  });

  /// Package namespace before `:`.
  final String namespace;

  /// Package name after `:`.
  final String name;

  /// Optional package version after `@`.
  final String? version;

  /// Source span for the package name boundary.
  final WASIComponentWitSpan span;

  /// Canonical text form of the package declaration target.
  String get text {
    final suffix = version == null ? '' : '@$version';
    return '$namespace:$name$suffix';
  }
}

/// Top-level WIT interface boundary.
final class WASIComponentWitInterface {
  /// Creates an interface declaration boundary.
  WASIComponentWitInterface({
    required this.name,
    required List<WASIComponentWitFunction> functions,
    required List<WASIComponentWitRecord> records,
    required List<WASIComponentWitVariant> variants,
    required List<WASIComponentWitFlags> flags,
    required List<WASIComponentWitEnum> enums,
    required this.span,
  }) : functions = List<WASIComponentWitFunction>.unmodifiable(functions),
       records = List<WASIComponentWitRecord>.unmodifiable(records),
       variants = List<WASIComponentWitVariant>.unmodifiable(variants),
       flags = List<WASIComponentWitFlags>.unmodifiable(flags),
       enums = List<WASIComponentWitEnum>.unmodifiable(enums);

  /// Interface name.
  final String name;

  /// Function declarations captured directly in this interface.
  final List<WASIComponentWitFunction> functions;

  /// Record declarations captured directly in this interface.
  final List<WASIComponentWitRecord> records;

  /// Variant declarations captured directly in this interface.
  final List<WASIComponentWitVariant> variants;

  /// Flags declarations captured directly in this interface.
  final List<WASIComponentWitFlags> flags;

  /// Enum declarations captured directly in this interface.
  final List<WASIComponentWitEnum> enums;

  /// Source span for the interface name.
  final WASIComponentWitSpan span;

  /// Returns the record named [name], if this interface declares one.
  WASIComponentWitRecord? recordNamed(String name) {
    for (final record in records) {
      if (record.name == name) {
        return record;
      }
    }
    return null;
  }

  /// Returns the variant named [name], if this interface declares one.
  WASIComponentWitVariant? variantNamed(String name) {
    for (final variant in variants) {
      if (variant.name == name) {
        return variant;
      }
    }
    return null;
  }

  /// Returns the flags type named [name], if this interface declares one.
  WASIComponentWitFlags? flagsNamed(String name) {
    for (final flagsType in flags) {
      if (flagsType.name == name) {
        return flagsType;
      }
    }
    return null;
  }

  /// Returns the enum named [name], if this interface declares one.
  WASIComponentWitEnum? enumNamed(String name) {
    for (final enum_ in enums) {
      if (enum_.name == name) {
        return enum_;
      }
    }
    return null;
  }
}

/// Record type declared directly in a WIT interface.
final class WASIComponentWitRecord {
  /// Creates a WIT record declaration boundary.
  WASIComponentWitRecord({
    required this.name,
    required List<WASIComponentWitRecordField> fields,
    required this.span,
  }) : fields = List<WASIComponentWitRecordField>.unmodifiable(fields);

  /// Record name.
  final String name;

  /// Ordered record fields.
  final List<WASIComponentWitRecordField> fields;

  /// Source span for the record name.
  final WASIComponentWitSpan span;
}

/// Field declared directly in a WIT record.
final class WASIComponentWitRecordField {
  /// Creates a WIT record field boundary.
  const WASIComponentWitRecordField({
    required this.name,
    required this.type,
    required this.span,
  });

  /// Field name.
  final String name;

  /// Compact field type text.
  final String type;

  /// Source span for the field name.
  final WASIComponentWitSpan span;
}

/// Variant type declared directly in a WIT interface.
final class WASIComponentWitVariant {
  /// Creates a WIT variant declaration boundary.
  WASIComponentWitVariant({
    required this.name,
    required List<WASIComponentWitVariantCase> cases,
    required this.span,
  }) : cases = List<WASIComponentWitVariantCase>.unmodifiable(cases);

  /// Variant name.
  final String name;

  /// Ordered variant cases.
  final List<WASIComponentWitVariantCase> cases;

  /// Source span for the variant name.
  final WASIComponentWitSpan span;
}

/// Case declared directly in a WIT variant.
final class WASIComponentWitVariantCase {
  /// Creates a WIT variant case boundary.
  const WASIComponentWitVariantCase({
    required this.name,
    required this.type,
    required this.span,
  });

  /// Case name.
  final String name;

  /// Compact payload type text, if this case carries a payload.
  final String? type;

  /// Source span for the case name.
  final WASIComponentWitSpan span;
}

/// Flags type declared directly in a WIT interface.
final class WASIComponentWitFlags {
  /// Creates a WIT flags declaration boundary.
  WASIComponentWitFlags({
    required this.name,
    required List<WASIComponentWitLabel> labels,
    required this.span,
  }) : labels = List<WASIComponentWitLabel>.unmodifiable(labels);

  /// Flags type name.
  final String name;

  /// Ordered flag labels.
  final List<WASIComponentWitLabel> labels;

  /// Source span for the flags name.
  final WASIComponentWitSpan span;
}

/// Enum type declared directly in a WIT interface.
final class WASIComponentWitEnum {
  /// Creates a WIT enum declaration boundary.
  WASIComponentWitEnum({
    required this.name,
    required List<WASIComponentWitLabel> cases,
    required this.span,
  }) : cases = List<WASIComponentWitLabel>.unmodifiable(cases);

  /// Enum name.
  final String name;

  /// Ordered enum cases.
  final List<WASIComponentWitLabel> cases;

  /// Source span for the enum name.
  final WASIComponentWitSpan span;
}

/// Label declared in a WIT flags or enum type.
final class WASIComponentWitLabel {
  /// Creates a WIT label boundary.
  const WASIComponentWitLabel({required this.name, required this.span});

  /// Label name.
  final String name;

  /// Source span for the label name.
  final WASIComponentWitSpan span;
}

/// Function boundary declared directly in a WIT interface.
final class WASIComponentWitFunction {
  /// Creates a WIT function boundary.
  const WASIComponentWitFunction({
    required this.name,
    required this.signature,
    required this.span,
  });

  /// Function name before `:`.
  final String name;

  /// Compact signature text after `:` and before `;`.
  final String signature;

  /// Source span for the function name.
  final WASIComponentWitSpan span;

  /// Whether the signature is an `async func`.
  bool get isAsync => signature.contains('asyncfunc');

  /// Whether this function uses Preview3-native async surface syntax.
  bool get usesPreview3AsyncFeatures =>
      isAsync || signature.contains('stream<') || signature.contains('future<');
}

/// Top-level WIT world boundary.
final class WASIComponentWitWorld {
  /// Creates a world declaration boundary.
  WASIComponentWitWorld({
    required this.name,
    required List<WASIComponentWitWorldItem> items,
    required this.span,
  }) : items = List<WASIComponentWitWorldItem>.unmodifiable(items);

  /// World name.
  final String name;

  /// Import/export items declared directly in this world.
  final List<WASIComponentWitWorldItem> items;

  /// Source span for the world name.
  final WASIComponentWitSpan span;

  /// Import items declared directly in this world.
  Iterable<WASIComponentWitWorldItem> get imports => items.where(
    (item) => item.direction == WASIComponentWitWorldItemDirection.import,
  );

  /// Export items declared directly in this world.
  Iterable<WASIComponentWitWorldItem> get exports => items.where(
    (item) => item.direction == WASIComponentWitWorldItemDirection.export,
  );

  /// Include items declared directly in this world.
  Iterable<WASIComponentWitWorldItem> get includes => items.where(
    (item) => item.direction == WASIComponentWitWorldItemDirection.include,
  );
}

/// Direction of a WIT world boundary item.
enum WASIComponentWitWorldItemDirection {
  /// `import` world item.
  import,

  /// `export` world item.
  export,

  /// `include` world item.
  include,
}

/// Import or export target declared directly in a WIT world.
final class WASIComponentWitWorldItem {
  /// Creates a world item boundary.
  const WASIComponentWitWorldItem({
    required this.direction,
    required this.target,
    required this.span,
  });

  /// Whether this item is an import or export.
  final WASIComponentWitWorldItemDirection direction;

  /// Parsed item target.
  final WASIComponentWitTarget target;

  /// Source span for the item target.
  final WASIComponentWitSpan span;

  /// Whether this item is an import.
  bool get isImport => direction == WASIComponentWitWorldItemDirection.import;

  /// Whether this item is an export.
  bool get isExport => direction == WASIComponentWitWorldItemDirection.export;
}

/// WIT world import/export target text.
final class WASIComponentWitTarget {
  /// Creates a target boundary.
  const WASIComponentWitTarget({required this.text, required this.span});

  /// Target text without trivia.
  final String text;

  /// Source span for the target start.
  final WASIComponentWitSpan span;

  /// Whether this target names an external package/interface path.
  bool get isQualified =>
      text.contains(':') || text.contains('/') || text.contains('@');

  /// Whether this target names a local interface in the same document.
  bool get isLocal => !isQualified;
}

/// Source span used for WIT diagnostics.
final class WASIComponentWitSpan {
  /// Creates a source span.
  const WASIComponentWitSpan({
    required this.sourceName,
    required this.offset,
    required this.line,
    required this.column,
    required this.length,
  });

  /// Human-readable source name.
  final String sourceName;

  /// Zero-based byte-like string offset in the Dart source string.
  final int offset;

  /// One-based line number.
  final int line;

  /// One-based column number.
  final int column;

  /// Span length in UTF-16 code units.
  final int length;

  /// `source:line:column` diagnostic location.
  String get location => '$sourceName:$line:$column';
}

/// Structured WIT parse diagnostic.
final class WASIComponentWitDiagnostic {
  /// Creates a parse diagnostic.
  const WASIComponentWitDiagnostic({
    required this.sourceName,
    required this.line,
    required this.column,
    required this.message,
  });

  /// Human-readable source name.
  final String sourceName;

  /// One-based line number.
  final int line;

  /// One-based column number.
  final int column;

  /// Diagnostic message.
  final String message;

  @override
  String toString() => '$sourceName:$line:$column: $message';
}

/// Exception thrown when WIT boundary parsing fails.
final class WASIComponentWitParseException implements Exception {
  /// Creates a WIT parse exception from [diagnostic].
  const WASIComponentWitParseException(this.diagnostic);

  /// Structured parse diagnostic.
  final WASIComponentWitDiagnostic diagnostic;

  @override
  String toString() => diagnostic.toString();
}

final class _WitParser {
  _WitParser(String source, String sourceName)
    : _lexer = _WitLexer(source, sourceName) {
    _advance();
  }

  final _WitLexer _lexer;
  final _interfacesByName = <String, WASIComponentWitInterface>{};
  final _worldsByName = <String, WASIComponentWitWorld>{};
  late _WitToken _current;

  WASIComponentWitDocument parse() {
    WASIComponentWitPackage? package;
    final interfaces = <WASIComponentWitInterface>[];
    final worlds = <WASIComponentWitWorld>[];

    while (!_checkKind(_WitTokenKind.eof)) {
      if (_checkSymbol('@')) {
        _skipAnnotation();
        continue;
      }
      if (_matchWord('package')) {
        if (package != null) {
          _fail(_current.span, 'duplicate package declaration');
        }
        package = _parsePackage();
        continue;
      }
      if (_matchWord('interface')) {
        final interface = _parseInterface();
        final first = _interfacesByName[interface.name];
        if (first != null) {
          _fail(
            interface.span,
            "duplicate interface '${interface.name}'; first declared at "
            '${first.span.location}',
          );
        }
        _interfacesByName[interface.name] = interface;
        interfaces.add(interface);
        continue;
      }
      if (_matchWord('world')) {
        final world = _parseWorld();
        final first = _worldsByName[world.name];
        if (first != null) {
          _fail(
            world.span,
            "duplicate world '${world.name}'; first declared at "
            '${first.span.location}',
          );
        }
        _worldsByName[world.name] = world;
        worlds.add(world);
        continue;
      }
      _fail(
        _current.span,
        "expected 'package', 'interface', or 'world', found "
        "'${_current.lexeme}'",
      );
    }

    for (final world in worlds) {
      _validateWorldReferences(world);
    }

    return WASIComponentWitDocument(
      package: package,
      interfaces: interfaces,
      worlds: worlds,
    );
  }

  WASIComponentWitPackage _parsePackage() {
    final namespace = _expectWord('package namespace');
    _expectSymbol(':');
    final name = _expectWord('package name');
    String? version;
    if (_matchSymbol('@')) {
      final versionStart = _current.span;
      final versionText = StringBuffer();
      while (!_checkSymbol(';') && !_checkKind(_WitTokenKind.eof)) {
        versionText.write(_current.lexeme);
        _advance();
      }
      if (versionText.isEmpty) {
        _fail(versionStart, 'expected package version after @');
      }
      version = versionText.toString();
    }
    _expectSymbol(';');
    return WASIComponentWitPackage(
      namespace: namespace.lexeme,
      name: name.lexeme,
      version: version,
      span: namespace.span,
    );
  }

  WASIComponentWitInterface _parseInterface() {
    final name = _expectWord('interface name');
    _expectSymbol('{');
    final functions = <WASIComponentWitFunction>[];
    final records = <WASIComponentWitRecord>[];
    final variants = <WASIComponentWitVariant>[];
    final flags = <WASIComponentWitFlags>[];
    final enums = <WASIComponentWitEnum>[];
    _parseInterfaceBlock(
      functions,
      records,
      variants,
      flags,
      enums,
      prefix: '',
    );
    return WASIComponentWitInterface(
      name: name.lexeme,
      functions: functions,
      records: records,
      variants: variants,
      flags: flags,
      enums: enums,
      span: name.span,
    );
  }

  void _parseInterfaceBlock(
    List<WASIComponentWitFunction> functions,
    List<WASIComponentWitRecord> records,
    List<WASIComponentWitVariant> variantTypes,
    List<WASIComponentWitFlags> flagsTypes,
    List<WASIComponentWitEnum> enumTypes, {
    required String prefix,
  }) {
    while (!_checkSymbol('}') && !_checkKind(_WitTokenKind.eof)) {
      if (_checkSymbol('@')) {
        _skipAnnotation();
        continue;
      }
      if (_matchWord('record')) {
        final record = _parseRecord();
        _failDuplicateInterfaceType(
          record.name,
          record.span,
          records,
          variantTypes,
          flagsTypes,
          enumTypes,
        );
        records.add(record);
        continue;
      }
      if (_matchWord('variant')) {
        final variant = _parseVariant();
        _failDuplicateInterfaceType(
          variant.name,
          variant.span,
          records,
          variantTypes,
          flagsTypes,
          enumTypes,
        );
        variantTypes.add(variant);
        continue;
      }
      if (_matchWord('flags')) {
        final flags = _parseFlags();
        _failDuplicateInterfaceType(
          flags.name,
          flags.span,
          records,
          variantTypes,
          flagsTypes,
          enumTypes,
        );
        flagsTypes.add(flags);
        continue;
      }
      if (_matchWord('enum')) {
        final enum_ = _parseEnum();
        _failDuplicateInterfaceType(
          enum_.name,
          enum_.span,
          records,
          variantTypes,
          flagsTypes,
          enumTypes,
        );
        enumTypes.add(enum_);
        continue;
      }
      if (_checkKind(_WitTokenKind.word)) {
        final item = _current;
        _advance();
        if (_matchSymbol(':')) {
          final signature = _parseInterfaceItemSignature(item.span);
          if (_isFunctionSignature(signature)) {
            functions.add(
              WASIComponentWitFunction(
                name: '$prefix${item.lexeme}',
                signature: signature,
                span: item.span,
              ),
            );
          }
          continue;
        }
        if (_checkSymbol('{')) {
          _advance();
          _parseInterfaceBlock(
            functions,
            records,
            variantTypes,
            flagsTypes,
            enumTypes,
            prefix: '$prefix${item.lexeme}.',
          );
          continue;
        }
        continue;
      }
      if (_checkSymbol('{')) {
        _advance();
        _parseInterfaceBlock(
          functions,
          records,
          variantTypes,
          flagsTypes,
          enumTypes,
          prefix: prefix,
        );
        continue;
      }
      _advance();
    }
    _expectSymbol('}');
  }

  WASIComponentWitRecord _parseRecord() {
    final name = _expectWord('record name');
    _expectSymbol('{');
    final fields = <WASIComponentWitRecordField>[];
    while (!_checkSymbol('}') && !_checkKind(_WitTokenKind.eof)) {
      if (_checkSymbol('@')) {
        _skipAnnotation();
        continue;
      }
      final field = _expectWord('record field name');
      _expectSymbol(':');
      final type = _parseInterfaceItemSignature(field.span);
      if (type.isEmpty) {
        _fail(field.span, "record field '${field.lexeme}' has empty type");
      }
      fields.add(
        WASIComponentWitRecordField(
          name: field.lexeme,
          type: type,
          span: field.span,
        ),
      );
    }
    _expectSymbol('}');
    return WASIComponentWitRecord(
      name: name.lexeme,
      fields: fields,
      span: name.span,
    );
  }

  WASIComponentWitVariant _parseVariant() {
    final name = _expectWord('variant name');
    _expectSymbol('{');
    final cases = <WASIComponentWitVariantCase>[];
    while (!_checkSymbol('}') && !_checkKind(_WitTokenKind.eof)) {
      if (_checkSymbol('@')) {
        _skipAnnotation();
        continue;
      }
      final case_ = _expectWord('variant case name');
      final first = _variantCaseNamed(cases, case_.lexeme);
      if (first != null) {
        _fail(
          case_.span,
          "duplicate variant case '${case_.lexeme}'; first declared at "
          '${first.span.location}',
        );
      }
      final type = _matchSymbol('(')
          ? _parseVariantCasePayloadType(case_.span)
          : null;
      cases.add(
        WASIComponentWitVariantCase(
          name: case_.lexeme,
          type: type,
          span: case_.span,
        ),
      );
      _matchSymbol(',');
    }
    _expectSymbol('}');
    return WASIComponentWitVariant(
      name: name.lexeme,
      cases: cases,
      span: name.span,
    );
  }

  String _parseVariantCasePayloadType(WASIComponentWitSpan start) {
    final text = StringBuffer();
    var parenDepth = 1;
    var angleDepth = 0;
    while (!_checkKind(_WitTokenKind.eof)) {
      if (_checkSymbol('(')) {
        parenDepth++;
      } else if (_checkSymbol(')') && angleDepth == 0) {
        parenDepth--;
        if (parenDepth == 0) {
          _advance();
          final result = text.toString();
          if (result.isEmpty) {
            _fail(start, 'variant case payload has empty type');
          }
          return result;
        }
      } else if (_checkSymbol('<')) {
        angleDepth++;
      } else if (_checkSymbol('>') && angleDepth > 0) {
        angleDepth--;
      }
      text.write(_current.lexeme);
      _advance();
    }
    _fail(start, 'unterminated variant case payload type');
  }

  WASIComponentWitFlags _parseFlags() {
    final name = _expectWord('flags name');
    _expectSymbol('{');
    final labels = _parseLabels('flag');
    return WASIComponentWitFlags(
      name: name.lexeme,
      labels: labels,
      span: name.span,
    );
  }

  WASIComponentWitEnum _parseEnum() {
    final name = _expectWord('enum name');
    _expectSymbol('{');
    final cases = _parseLabels('enum case');
    return WASIComponentWitEnum(
      name: name.lexeme,
      cases: cases,
      span: name.span,
    );
  }

  List<WASIComponentWitLabel> _parseLabels(String labelKind) {
    final labels = <WASIComponentWitLabel>[];
    while (!_checkSymbol('}') && !_checkKind(_WitTokenKind.eof)) {
      if (_checkSymbol('@')) {
        _skipAnnotation();
        continue;
      }
      final label = _expectWord(labelKind);
      final first = _labelNamed(labels, label.lexeme);
      if (first != null) {
        _fail(
          label.span,
          "duplicate $labelKind '${label.lexeme}'; first declared at "
          '${first.span.location}',
        );
      }
      labels.add(WASIComponentWitLabel(name: label.lexeme, span: label.span));
      _matchSymbol(',');
    }
    _expectSymbol('}');
    return labels;
  }

  WASIComponentWitRecord? _recordNamed(
    List<WASIComponentWitRecord> records,
    String name,
  ) {
    for (final record in records) {
      if (record.name == name) {
        return record;
      }
    }
    return null;
  }

  WASIComponentWitVariantCase? _variantCaseNamed(
    List<WASIComponentWitVariantCase> cases,
    String name,
  ) {
    for (final case_ in cases) {
      if (case_.name == name) {
        return case_;
      }
    }
    return null;
  }

  WASIComponentWitLabel? _labelNamed(
    List<WASIComponentWitLabel> labels,
    String name,
  ) {
    for (final label in labels) {
      if (label.name == name) {
        return label;
      }
    }
    return null;
  }

  void _failDuplicateInterfaceType(
    String name,
    WASIComponentWitSpan span,
    List<WASIComponentWitRecord> records,
    List<WASIComponentWitVariant> variants,
    List<WASIComponentWitFlags> flags,
    List<WASIComponentWitEnum> enums,
  ) {
    final first = _interfaceTypeNamed(name, records, variants, flags, enums);
    if (first == null) {
      return;
    }
    _fail(
      span,
      "duplicate interface type '$name'; first ${first.kind} declared at "
      '${first.span.location}',
    );
  }

  ({String kind, WASIComponentWitSpan span})? _interfaceTypeNamed(
    String name,
    List<WASIComponentWitRecord> records,
    List<WASIComponentWitVariant> variants,
    List<WASIComponentWitFlags> flags,
    List<WASIComponentWitEnum> enums,
  ) {
    final record = _recordNamed(records, name);
    if (record != null) {
      return (kind: 'record', span: record.span);
    }
    for (final variant in variants) {
      if (variant.name == name) {
        return (kind: 'variant', span: variant.span);
      }
    }
    for (final flagsType in flags) {
      if (flagsType.name == name) {
        return (kind: 'flags', span: flagsType.span);
      }
    }
    for (final enum_ in enums) {
      if (enum_.name == name) {
        return (kind: 'enum', span: enum_.span);
      }
    }
    return null;
  }

  WASIComponentWitWorld _parseWorld() {
    final name = _expectWord('world name');
    _expectSymbol('{');
    final items = <WASIComponentWitWorldItem>[];
    while (!_checkSymbol('}') && !_checkKind(_WitTokenKind.eof)) {
      if (_checkSymbol('@')) {
        _skipAnnotation();
        continue;
      }
      if (_matchWord('import')) {
        items.add(_parseWorldItem(WASIComponentWitWorldItemDirection.import));
        continue;
      }
      if (_matchWord('export')) {
        items.add(_parseWorldItem(WASIComponentWitWorldItemDirection.export));
        continue;
      }
      if (_matchWord('include')) {
        items.add(_parseWorldItem(WASIComponentWitWorldItemDirection.include));
        continue;
      }
      _skipWorldDeclaration();
    }
    _expectSymbol('}');
    return WASIComponentWitWorld(
      name: name.lexeme,
      items: items,
      span: name.span,
    );
  }

  WASIComponentWitWorldItem _parseWorldItem(
    WASIComponentWitWorldItemDirection direction,
  ) {
    final targetStart = _current.span;
    final targetText = StringBuffer();
    var terminated = false;
    while (!_checkSymbol(';') && !_checkKind(_WitTokenKind.eof)) {
      if (_checkSymbol('}')) {
        break;
      }
      if (_checkSymbol('{')) {
        _advance();
        _skipBalancedBlock();
        _matchSymbol(';');
        terminated = true;
        break;
      }
      targetText.write(_current.lexeme);
      _advance();
    }
    if (_checkSymbol(';')) {
      _advance();
      terminated = true;
    }
    if (targetText.isEmpty) {
      _fail(targetStart, 'expected world ${direction.name} target');
    }
    if (!terminated) {
      _fail(targetStart, 'unterminated world ${direction.name} target');
    }
    final target = WASIComponentWitTarget(
      text: targetText.toString(),
      span: targetStart,
    );
    return WASIComponentWitWorldItem(
      direction: direction,
      target: target,
      span: targetStart,
    );
  }

  void _validateWorldReferences(WASIComponentWitWorld world) {
    for (final item in world.items) {
      if (!item.target.isLocal) {
        continue;
      }
      final found = item.direction == WASIComponentWitWorldItemDirection.include
          ? _worldsByName.containsKey(item.target.text)
          : _interfacesByName.containsKey(item.target.text);
      if (found) {
        continue;
      }
      final direction = item.direction.name;
      final boundary =
          item.direction == WASIComponentWitWorldItemDirection.include
          ? 'world'
          : 'interface';
      _fail(
        item.target.span,
        "world '${world.name}' $direction references unknown local $boundary "
        "'${item.target.text}'",
      );
    }
  }

  String _parseInterfaceItemSignature(WASIComponentWitSpan start) {
    final text = StringBuffer();
    var parenDepth = 0;
    var angleDepth = 0;
    while (!_checkKind(_WitTokenKind.eof)) {
      if (parenDepth == 0 && angleDepth == 0 && _checkSymbol(';')) {
        _advance();
        return text.toString();
      }
      if (parenDepth == 0 && angleDepth == 0 && _checkSymbol(',')) {
        _advance();
        return text.toString();
      }
      if (parenDepth == 0 && angleDepth == 0 && _checkSymbol('}')) {
        return text.toString();
      }
      if (_checkSymbol('}')) {
        _fail(start, 'unterminated interface item signature');
      }
      if (_checkSymbol('{')) {
        _advance();
        _skipBalancedBlock();
        continue;
      }
      if (_checkSymbol('(')) {
        parenDepth++;
      } else if (_checkSymbol(')') && parenDepth > 0) {
        parenDepth--;
      } else if (_checkSymbol('<')) {
        angleDepth++;
      } else if (_checkSymbol('>') && angleDepth > 0) {
        angleDepth--;
      }
      text.write(_current.lexeme);
      _advance();
    }
    _fail(start, 'unterminated interface item signature');
  }

  bool _isFunctionSignature(String signature) {
    return signature == 'func' ||
        signature.startsWith('func(') ||
        signature.contains('func(') ||
        signature.contains('asyncfunc(');
  }

  void _skipAnnotation() {
    _expectSymbol('@');
    if (_checkKind(_WitTokenKind.word)) {
      _advance();
    }
    if (_matchSymbol('(')) {
      var depth = 1;
      while (depth > 0) {
        if (_checkKind(_WitTokenKind.eof)) {
          _fail(_current.span, 'unterminated WIT annotation');
        }
        if (_checkSymbol('(')) {
          depth++;
        } else if (_checkSymbol(')')) {
          depth--;
        }
        _advance();
      }
    }
  }

  void _skipBalancedBlock() {
    var depth = 1;
    while (depth > 0) {
      if (_checkKind(_WitTokenKind.eof)) {
        _fail(_current.span, 'unterminated WIT block');
      }
      if (_checkSymbol('{')) {
        depth++;
      } else if (_checkSymbol('}')) {
        depth--;
      }
      _advance();
    }
  }

  void _skipWorldDeclaration() {
    while (!_checkKind(_WitTokenKind.eof)) {
      if (_checkSymbol(';')) {
        _advance();
        return;
      }
      if (_checkSymbol('}')) {
        return;
      }
      if (_checkSymbol('{')) {
        _advance();
        _skipBalancedBlock();
        continue;
      }
      _advance();
    }
  }

  _WitToken _expectWord(String context) {
    if (_checkKind(_WitTokenKind.word)) {
      final token = _current;
      _advance();
      return token;
    }
    _fail(_current.span, 'expected $context');
  }

  void _expectSymbol(String symbol) {
    if (_matchSymbol(symbol)) {
      return;
    }
    _fail(_current.span, "expected '$symbol'");
  }

  bool _matchWord(String word) {
    if (!_checkWord(word)) {
      return false;
    }
    _advance();
    return true;
  }

  bool _matchSymbol(String symbol) {
    if (!_checkSymbol(symbol)) {
      return false;
    }
    _advance();
    return true;
  }

  bool _checkWord(String word) =>
      _current.kind == _WitTokenKind.word && _current.lexeme == word;

  bool _checkSymbol(String symbol) =>
      _current.kind == _WitTokenKind.symbol && _current.lexeme == symbol;

  bool _checkKind(_WitTokenKind kind) => _current.kind == kind;

  void _advance() {
    _current = _lexer.next();
  }

  Never _fail(WASIComponentWitSpan span, String message) {
    throw WASIComponentWitParseException(
      WASIComponentWitDiagnostic(
        sourceName: span.sourceName,
        line: span.line,
        column: span.column,
        message: message,
      ),
    );
  }
}

enum _WitTokenKind { word, symbol, eof }

final class _WitToken {
  const _WitToken({
    required this.kind,
    required this.lexeme,
    required this.span,
  });

  final _WitTokenKind kind;
  final String lexeme;
  final WASIComponentWitSpan span;
}

final class _WitLexer {
  _WitLexer(this._source, this._sourceName);

  final String _source;
  final String _sourceName;
  int _offset = 0;
  int _line = 1;
  int _column = 1;

  _WitToken next() {
    _skipTrivia();
    if (_isAtEnd) {
      return _WitToken(
        kind: _WitTokenKind.eof,
        lexeme: '',
        span: _spanAtCurrent(0),
      );
    }

    final startOffset = _offset;
    final startLine = _line;
    final startColumn = _column;
    final code = _source.codeUnitAt(_offset);
    if (_isWordStart(code)) {
      final text = StringBuffer();
      while (!_isAtEnd && _isWordPart(_source.codeUnitAt(_offset))) {
        text.writeCharCode(_source.codeUnitAt(_offset));
        _advanceChar();
      }
      return _WitToken(
        kind: _WitTokenKind.word,
        lexeme: text.toString(),
        span: _span(startOffset, startLine, startColumn),
      );
    }

    final lexeme = String.fromCharCode(code);
    _advanceChar();
    return _WitToken(
      kind: _WitTokenKind.symbol,
      lexeme: lexeme,
      span: _span(startOffset, startLine, startColumn),
    );
  }

  void _skipTrivia() {
    while (!_isAtEnd) {
      final code = _source.codeUnitAt(_offset);
      if (_isWhitespace(code)) {
        _advanceChar();
        continue;
      }
      if (_startsWith('//')) {
        while (!_isAtEnd && _source.codeUnitAt(_offset) != 10) {
          _advanceChar();
        }
        continue;
      }
      if (_startsWith('/*')) {
        _skipBlockComment();
        continue;
      }
      return;
    }
  }

  void _skipBlockComment() {
    final start = _spanAtCurrent(2);
    _advanceChar();
    _advanceChar();
    while (!_isAtEnd) {
      if (_startsWith('*/')) {
        _advanceChar();
        _advanceChar();
        return;
      }
      _advanceChar();
    }
    throw WASIComponentWitParseException(
      WASIComponentWitDiagnostic(
        sourceName: start.sourceName,
        line: start.line,
        column: start.column,
        message: 'unterminated block comment',
      ),
    );
  }

  bool _startsWith(String value) => _source.startsWith(value, _offset);

  bool get _isAtEnd => _offset >= _source.length;

  WASIComponentWitSpan _spanAtCurrent(int length) {
    return WASIComponentWitSpan(
      sourceName: _sourceName,
      offset: _offset,
      line: _line,
      column: _column,
      length: length,
    );
  }

  WASIComponentWitSpan _span(int offset, int line, int column) {
    return WASIComponentWitSpan(
      sourceName: _sourceName,
      offset: offset,
      line: line,
      column: column,
      length: _offset - offset,
    );
  }

  void _advanceChar() {
    if (_isAtEnd) {
      return;
    }
    final code = _source.codeUnitAt(_offset);
    _offset++;
    if (code == 10) {
      _line++;
      _column = 1;
      return;
    }
    _column++;
  }
}

bool _isWhitespace(int code) =>
    code == 9 || code == 10 || code == 13 || code == 32;

bool _isWordStart(int code) =>
    _isAsciiLetter(code) || _isDigit(code) || code == 37;

bool _isWordPart(int code) =>
    _isAsciiLetter(code) ||
    _isDigit(code) ||
    code == 37 ||
    code == 45 ||
    code == 95;

bool _isAsciiLetter(int code) =>
    (code >= 65 && code <= 90) || (code >= 97 && code <= 122);

bool _isDigit(int code) => code >= 48 && code <= 57;
