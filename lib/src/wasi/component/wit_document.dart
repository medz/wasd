import 'dart:convert';

/// WIT document boundary model for Preview2/Preview3 adapters.
///
/// This parser intentionally stops at package/interface/world boundaries. It
/// gives adapter generation a structured, diagnosable input without claiming
/// full WIT semantic coverage.
final class WASIComponentWitDocument {
  /// Creates a parsed WIT document from already-normalized declarations.
  WASIComponentWitDocument({
    required List<WASIComponentWitInterface> interfaces,
    required List<WASIComponentWitWorld> worlds,
    this.package,
  }) : interfaces = List<WASIComponentWitInterface>.unmodifiable(interfaces),
       worlds = List<WASIComponentWitWorld>.unmodifiable(worlds);

  /// Parses [source] into the package/interface/world boundary model.
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
    required List<WASIComponentWitResource> resources,
    required List<WASIComponentWitTypeAlias> typeAliases,
    required List<WASIComponentWitUse> uses,
    required this.span,
  }) : functions = List<WASIComponentWitFunction>.unmodifiable(functions),
       records = List<WASIComponentWitRecord>.unmodifiable(records),
       variants = List<WASIComponentWitVariant>.unmodifiable(variants),
       flags = List<WASIComponentWitFlags>.unmodifiable(flags),
       enums = List<WASIComponentWitEnum>.unmodifiable(enums),
       resources = List<WASIComponentWitResource>.unmodifiable(resources),
       typeAliases = List<WASIComponentWitTypeAlias>.unmodifiable(typeAliases),
       uses = List<WASIComponentWitUse>.unmodifiable(uses);

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

  /// Resource declarations captured directly in this interface.
  final List<WASIComponentWitResource> resources;

  /// Type aliases declared directly in this interface.
  final List<WASIComponentWitTypeAlias> typeAliases;

  /// `use` declarations captured directly in this interface.
  final List<WASIComponentWitUse> uses;

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

  /// Returns the resource named [name], if this interface declares one.
  WASIComponentWitResource? resourceNamed(String name) {
    for (final resource in resources) {
      if (resource.name == name) {
        return resource;
      }
    }
    return null;
  }

  /// Returns the type alias named [name], if this interface declares one.
  WASIComponentWitTypeAlias? typeAliasNamed(String name) {
    for (final alias in typeAliases) {
      if (alias.name == name) {
        return alias;
      }
    }
    return null;
  }

  /// Returns the used type item aliased as [name], if this interface has one.
  WASIComponentWitUseItem? useItemNamed(String name) {
    for (final use in uses) {
      for (final item in use.items) {
        if (item.alias == name) {
          return item;
        }
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
    this.externalId,
  }) : fields = List<WASIComponentWitRecordField>.unmodifiable(fields);

  /// Record name.
  final String name;

  /// Ordered record fields.
  final List<WASIComponentWitRecordField> fields;

  /// Source span for the record name.
  final WASIComponentWitSpan span;

  /// Optional platform identifier; the WIT name remains the linking key.
  final String? externalId;
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
    this.externalId,
  }) : cases = List<WASIComponentWitVariantCase>.unmodifiable(cases);

  /// Variant name.
  final String name;

  /// Ordered variant cases.
  final List<WASIComponentWitVariantCase> cases;

  /// Source span for the variant name.
  final WASIComponentWitSpan span;

  /// Optional platform identifier; the WIT name remains the linking key.
  final String? externalId;
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
    this.externalId,
  }) : labels = List<WASIComponentWitLabel>.unmodifiable(labels);

  /// Flags type name.
  final String name;

  /// Ordered flag labels.
  final List<WASIComponentWitLabel> labels;

  /// Source span for the flags name.
  final WASIComponentWitSpan span;

  /// Optional platform identifier; the WIT name remains the linking key.
  final String? externalId;
}

/// Enum type declared directly in a WIT interface.
final class WASIComponentWitEnum {
  /// Creates a WIT enum declaration boundary.
  WASIComponentWitEnum({
    required this.name,
    required List<WASIComponentWitLabel> cases,
    required this.span,
    this.externalId,
  }) : cases = List<WASIComponentWitLabel>.unmodifiable(cases);

  /// Enum name.
  final String name;

  /// Ordered enum cases.
  final List<WASIComponentWitLabel> cases;

  /// Source span for the enum name.
  final WASIComponentWitSpan span;

  /// Optional platform identifier; the WIT name remains the linking key.
  final String? externalId;
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

/// Resource type declared directly in a WIT interface.
final class WASIComponentWitResource {
  /// Creates a WIT resource declaration boundary.
  const WASIComponentWitResource({
    required this.name,
    required this.span,
    this.externalId,
  });

  /// Resource name.
  final String name;

  /// Source span for the resource name.
  final WASIComponentWitSpan span;

  /// Optional platform identifier; the WIT name remains the linking key.
  final String? externalId;
}

/// Type alias declared directly in a WIT interface.
final class WASIComponentWitTypeAlias {
  /// Creates a WIT type alias boundary.
  const WASIComponentWitTypeAlias({
    required this.name,
    required this.target,
    required this.span,
    this.externalId,
  });

  /// Alias name.
  final String name;

  /// Compact aliased type text after `=`.
  final String target;

  /// Source span for the alias name.
  final WASIComponentWitSpan span;

  /// Optional platform identifier; the WIT name remains the linking key.
  final String? externalId;
}

/// WIT `use target.{items}` declaration captured in an interface.
final class WASIComponentWitUse {
  /// Creates a WIT use boundary.
  WASIComponentWitUse({
    required this.target,
    required List<WASIComponentWitUseItem> items,
    required this.span,
  }) : items = List<WASIComponentWitUseItem>.unmodifiable(items);

  /// Qualified interface target being used.
  final WASIComponentWitTarget target;

  /// Used items, preserving declaration order.
  final List<WASIComponentWitUseItem> items;

  /// Source span for the use declaration target.
  final WASIComponentWitSpan span;
}

/// One item inside a WIT `use` declaration.
final class WASIComponentWitUseItem {
  /// Creates a WIT use item boundary.
  const WASIComponentWitUseItem({
    required this.name,
    required this.alias,
    required this.target,
    required this.span,
  });

  /// Name exported by the used interface.
  final String name;

  /// Local alias available in the current interface.
  final String alias;

  /// Target interface containing [name].
  final WASIComponentWitTarget target;

  /// Source span for the item name.
  final WASIComponentWitSpan span;
}

/// Function boundary declared directly in a WIT interface.
final class WASIComponentWitFunction {
  /// Creates a WIT function boundary.
  const WASIComponentWitFunction({
    required this.name,
    required this.signature,
    required this.span,
    this.externalId,
    this.isConstructor = false,
  });

  /// Function name before `:`.
  final String name;

  /// Compact signature text after `:` and before `;`.
  final String signature;

  /// Whether this is resource constructor syntax rather than a named function.
  final bool isConstructor;

  /// Callback name, retaining the historical spelling of a resource method
  /// named `constructor` so it cannot alias the resource's constructor.
  String get callbackName => !isConstructor && name.endsWith('.constructor')
      ? '${name.substring(0, name.length - 'constructor'.length)}%constructor'
      : name;

  /// Source span for the function name.
  final WASIComponentWitSpan span;

  /// Optional platform identifier; the WIT name remains the linking key.
  final String? externalId;

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
    this.name,
    this.externalId,
    this.renames = const <String, String>{},
  });

  /// Whether this item is an import or export.
  final WASIComponentWitWorldItemDirection direction;

  /// Plain binding label for an explicitly named import or export.
  final String? name;

  /// Optional platform identifier; it does not replace [name].
  final String? externalId;

  /// Plain-name substitutions on an `include ... with` item.
  final Map<String, String> renames;

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
      namespace: namespace.identifier,
      name: name.identifier,
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
    final resources = <WASIComponentWitResource>[];
    final typeAliases = <WASIComponentWitTypeAlias>[];
    final uses = <WASIComponentWitUse>[];
    _parseInterfaceBlock(
      functions,
      records,
      variants,
      flags,
      enums,
      resources,
      typeAliases: typeAliases,
      uses: uses,
      prefix: '',
      receiverResource: null,
    );
    return WASIComponentWitInterface(
      name: name.identifier,
      functions: functions,
      records: records,
      variants: variants,
      flags: flags,
      enums: enums,
      resources: resources,
      typeAliases: typeAliases,
      uses: uses,
      span: name.span,
    );
  }

  void _parseInterfaceBlock(
    List<WASIComponentWitFunction> functions,
    List<WASIComponentWitRecord> records,
    List<WASIComponentWitVariant> variantTypes,
    List<WASIComponentWitFlags> flagsTypes,
    List<WASIComponentWitEnum> enumTypes,
    List<WASIComponentWitResource> resourceTypes, {
    required List<WASIComponentWitTypeAlias> typeAliases,
    required List<WASIComponentWitUse> uses,
    required String prefix,
    required String? receiverResource,
  }) {
    while (!_checkSymbol('}') && !_checkKind(_WitTokenKind.eof)) {
      final externalId = _parseAnnotations(allowExternalId: true);
      if (externalId != null && _checkWord('use')) {
        _fail(_current.span, 'external-id is not valid on a use declaration');
      }
      if (_matchWord('use')) {
        final use = _parseUse();
        _failDuplicateUseItems(
          use,
          records,
          variantTypes,
          flagsTypes,
          enumTypes,
          resourceTypes,
          typeAliases,
          uses,
        );
        uses.add(use);
        continue;
      }
      if (_matchWord('type')) {
        final alias = _parseTypeAlias(externalId: externalId);
        _failDuplicateInterfaceType(
          alias.name,
          alias.span,
          records,
          variantTypes,
          flagsTypes,
          enumTypes,
          resourceTypes,
          typeAliases,
          uses,
        );
        typeAliases.add(alias);
        continue;
      }
      if (_matchWord('record')) {
        final record = _parseRecord(externalId: externalId);
        _failDuplicateInterfaceType(
          record.name,
          record.span,
          records,
          variantTypes,
          flagsTypes,
          enumTypes,
          resourceTypes,
          typeAliases,
          uses,
        );
        records.add(record);
        continue;
      }
      if (_matchWord('variant')) {
        final variant = _parseVariant(externalId: externalId);
        _failDuplicateInterfaceType(
          variant.name,
          variant.span,
          records,
          variantTypes,
          flagsTypes,
          enumTypes,
          resourceTypes,
          typeAliases,
          uses,
        );
        variantTypes.add(variant);
        continue;
      }
      if (_matchWord('flags')) {
        final flags = _parseFlags(externalId: externalId);
        _failDuplicateInterfaceType(
          flags.name,
          flags.span,
          records,
          variantTypes,
          flagsTypes,
          enumTypes,
          resourceTypes,
          typeAliases,
          uses,
        );
        flagsTypes.add(flags);
        continue;
      }
      if (_matchWord('enum')) {
        final enum_ = _parseEnum(externalId: externalId);
        _failDuplicateInterfaceType(
          enum_.name,
          enum_.span,
          records,
          variantTypes,
          flagsTypes,
          enumTypes,
          resourceTypes,
          typeAliases,
          uses,
        );
        enumTypes.add(enum_);
        continue;
      }
      if (_matchWord('resource')) {
        _parseResource(
          functions,
          records,
          variantTypes,
          flagsTypes,
          enumTypes,
          resourceTypes,
          typeAliases: typeAliases,
          uses: uses,
          prefix: prefix,
          externalId: externalId,
        );
        continue;
      }
      if (_checkKind(_WitTokenKind.word)) {
        final item = _current;
        _advance();
        if (receiverResource != null &&
            item.lexeme == 'constructor' &&
            _checkSymbol('(')) {
          final params = _parseConstructorParams(item.span);
          _addInterfaceFunction(
            functions,
            WASIComponentWitFunction(
              name: '$prefix${item.identifier}',
              signature: 'func($params)->$receiverResource',
              span: item.span,
              externalId: externalId,
              isConstructor: true,
            ),
          );
          continue;
        }
        if (_matchSymbol(':')) {
          final parsedSignature = _parseInterfaceItemSignature(item.span);
          final signature = _normalizeResourceFunctionSignature(
            parsedSignature,
            receiverResource,
          );
          if (_isFunctionSignature(signature)) {
            _addInterfaceFunction(
              functions,
              WASIComponentWitFunction(
                name: '$prefix${item.identifier}',
                signature: signature,
                span: item.span,
                externalId: externalId,
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
            resourceTypes,
            typeAliases: typeAliases,
            uses: uses,
            prefix: '$prefix${item.identifier}.',
            receiverResource: receiverResource,
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
          resourceTypes,
          typeAliases: typeAliases,
          uses: uses,
          prefix: prefix,
          receiverResource: receiverResource,
        );
        continue;
      }
      _advance();
    }
    _expectSymbol('}');
  }

  void _addInterfaceFunction(
    List<WASIComponentWitFunction> functions,
    WASIComponentWitFunction function,
  ) {
    for (final first in functions) {
      if (first.name == function.name &&
          first.isConstructor == function.isConstructor) {
        _fail(
          function.span,
          "duplicate function '${function.name}'; first declared at "
          '${first.span.location}',
        );
      }
    }
    functions.add(function);
  }

  String _parseConstructorParams(WASIComponentWitSpan start) {
    final text = StringBuffer();
    _expectSymbol('(');
    var parenDepth = 1;
    var angleDepth = 0;
    while (!_checkKind(_WitTokenKind.eof)) {
      if (_checkSymbol('(')) {
        parenDepth++;
      } else if (_checkSymbol(')') && angleDepth == 0) {
        parenDepth--;
        if (parenDepth == 0) {
          _advance();
          _expectSymbol(';');
          return text.toString();
        }
      } else if (_checkSymbol('<')) {
        angleDepth++;
      } else if (_checkSymbol('>') && angleDepth > 0) {
        angleDepth--;
      }
      text.write(_current.lexeme);
      _advance();
    }
    _fail(start, 'unterminated resource constructor');
  }

  WASIComponentWitUse _parseUse() {
    final targetStart = _current.span;
    final targetText = StringBuffer();
    while (!_checkKind(_WitTokenKind.eof)) {
      if (_checkSymbol('.')) {
        final dot = _current;
        _advance();
        if (_checkSymbol('{')) {
          break;
        }
        targetText.write(dot.lexeme);
        continue;
      }
      if (_checkSymbol(';') || _checkSymbol('}')) {
        _fail(targetStart, 'unterminated WIT use declaration');
      }
      targetText.write(_current.identifier);
      _advance();
    }
    if (targetText.isEmpty) {
      _fail(targetStart, 'expected WIT use target');
    }
    _expectSymbol('{');
    final target = WASIComponentWitTarget(
      text: targetText.toString(),
      span: targetStart,
    );
    final items = <WASIComponentWitUseItem>[];
    while (!_checkSymbol('}') && !_checkKind(_WitTokenKind.eof)) {
      final item = _expectWord('use item name');
      var alias = item.identifier;
      if (_matchWord('as')) {
        alias = _expectWord('use item alias').identifier;
      }
      final first = _useItemNamed(items, alias);
      if (first != null) {
        _fail(
          item.span,
          "duplicate use item alias '$alias'; first declared at "
          '${first.span.location}',
        );
      }
      items.add(
        WASIComponentWitUseItem(
          name: item.identifier,
          alias: alias,
          target: target,
          span: item.span,
        ),
      );
      _matchSymbol(',');
    }
    _expectSymbol('}');
    _expectSymbol(';');
    if (items.isEmpty) {
      _fail(targetStart, 'WIT use declaration must name at least one item');
    }
    return WASIComponentWitUse(target: target, items: items, span: targetStart);
  }

  WASIComponentWitTypeAlias _parseTypeAlias({String? externalId}) {
    final name = _expectWord('type alias name');
    _expectSymbol('=');
    final target = _parseInterfaceItemSignature(name.span);
    if (target.isEmpty) {
      _fail(name.span, "type alias '${name.lexeme}' has empty target");
    }
    return WASIComponentWitTypeAlias(
      name: name.identifier,
      target: target,
      span: name.span,
      externalId: externalId,
    );
  }

  void _parseResource(
    List<WASIComponentWitFunction> functions,
    List<WASIComponentWitRecord> records,
    List<WASIComponentWitVariant> variantTypes,
    List<WASIComponentWitFlags> flagsTypes,
    List<WASIComponentWitEnum> enumTypes,
    List<WASIComponentWitResource> resourceTypes, {
    required List<WASIComponentWitTypeAlias> typeAliases,
    required List<WASIComponentWitUse> uses,
    required String prefix,
    String? externalId,
  }) {
    final name = _expectWord('resource name');
    _failDuplicateInterfaceType(
      name.identifier,
      name.span,
      records,
      variantTypes,
      flagsTypes,
      enumTypes,
      resourceTypes,
      typeAliases,
      uses,
    );
    resourceTypes.add(
      WASIComponentWitResource(
        name: name.identifier,
        span: name.span,
        externalId: externalId,
      ),
    );
    if (_matchSymbol(';')) {
      return;
    }
    _expectSymbol('{');
    _parseInterfaceBlock(
      functions,
      records,
      variantTypes,
      flagsTypes,
      enumTypes,
      resourceTypes,
      typeAliases: typeAliases,
      uses: uses,
      prefix: '$prefix${name.identifier}.',
      receiverResource: name.lexeme,
    );
  }

  WASIComponentWitRecord _parseRecord({String? externalId}) {
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
          name: field.identifier,
          type: type,
          span: field.span,
        ),
      );
    }
    _expectSymbol('}');
    return WASIComponentWitRecord(
      name: name.identifier,
      fields: fields,
      span: name.span,
      externalId: externalId,
    );
  }

  WASIComponentWitVariant _parseVariant({String? externalId}) {
    final name = _expectWord('variant name');
    _expectSymbol('{');
    final cases = <WASIComponentWitVariantCase>[];
    while (!_checkSymbol('}') && !_checkKind(_WitTokenKind.eof)) {
      if (_checkSymbol('@')) {
        _skipAnnotation();
        continue;
      }
      final case_ = _expectWord('variant case name');
      final first = _variantCaseNamed(cases, case_.identifier);
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
          name: case_.identifier,
          type: type,
          span: case_.span,
        ),
      );
      _matchSymbol(',');
    }
    _expectSymbol('}');
    return WASIComponentWitVariant(
      name: name.identifier,
      cases: cases,
      span: name.span,
      externalId: externalId,
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

  WASIComponentWitFlags _parseFlags({String? externalId}) {
    final name = _expectWord('flags name');
    _expectSymbol('{');
    final labels = _parseLabels('flag');
    return WASIComponentWitFlags(
      name: name.identifier,
      labels: labels,
      span: name.span,
      externalId: externalId,
    );
  }

  WASIComponentWitEnum _parseEnum({String? externalId}) {
    final name = _expectWord('enum name');
    _expectSymbol('{');
    final cases = _parseLabels('enum case');
    return WASIComponentWitEnum(
      name: name.identifier,
      cases: cases,
      span: name.span,
      externalId: externalId,
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
      final first = _labelNamed(labels, label.identifier);
      if (first != null) {
        _fail(
          label.span,
          "duplicate $labelKind '${label.lexeme}'; first declared at "
          '${first.span.location}',
        );
      }
      labels.add(
        WASIComponentWitLabel(name: label.identifier, span: label.span),
      );
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

  WASIComponentWitUseItem? _useItemNamed(
    List<WASIComponentWitUseItem> items,
    String alias,
  ) {
    for (final item in items) {
      if (item.alias == alias) {
        return item;
      }
    }
    return null;
  }

  void _failDuplicateUseItems(
    WASIComponentWitUse use,
    List<WASIComponentWitRecord> records,
    List<WASIComponentWitVariant> variants,
    List<WASIComponentWitFlags> flags,
    List<WASIComponentWitEnum> enums,
    List<WASIComponentWitResource> resources,
    List<WASIComponentWitTypeAlias> aliases,
    List<WASIComponentWitUse> uses,
  ) {
    for (final item in use.items) {
      _failDuplicateInterfaceType(
        item.alias,
        item.span,
        records,
        variants,
        flags,
        enums,
        resources,
        aliases,
        uses,
      );
    }
  }

  void _failDuplicateInterfaceType(
    String name,
    WASIComponentWitSpan span,
    List<WASIComponentWitRecord> records,
    List<WASIComponentWitVariant> variants,
    List<WASIComponentWitFlags> flags,
    List<WASIComponentWitEnum> enums,
    List<WASIComponentWitResource> resources,
    List<WASIComponentWitTypeAlias> aliases,
    List<WASIComponentWitUse> uses,
  ) {
    final first = _interfaceTypeNamed(
      name,
      records,
      variants,
      flags,
      enums,
      resources,
      aliases,
      uses,
    );
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
    List<WASIComponentWitResource> resources,
    List<WASIComponentWitTypeAlias> aliases,
    List<WASIComponentWitUse> uses,
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
    for (final resource in resources) {
      if (resource.name == name) {
        return (kind: 'resource', span: resource.span);
      }
    }
    for (final alias in aliases) {
      if (alias.name == name) {
        return (kind: 'type alias', span: alias.span);
      }
    }
    for (final use in uses) {
      for (final item in use.items) {
        if (item.alias == name) {
          return (kind: 'use item', span: item.span);
        }
      }
    }
    return null;
  }

  WASIComponentWitWorld _parseWorld() {
    final name = _expectWord('world name');
    _expectSymbol('{');
    final items = <WASIComponentWitWorldItem>[];
    while (!_checkSymbol('}') && !_checkKind(_WitTokenKind.eof)) {
      final externalId = _parseAnnotations(allowExternalId: true);
      if (_matchWord('import')) {
        items.add(
          _parseWorldItem(
            WASIComponentWitWorldItemDirection.import,
            externalId: externalId,
          ),
        );
        continue;
      }
      if (_matchWord('export')) {
        items.add(
          _parseWorldItem(
            WASIComponentWitWorldItemDirection.export,
            externalId: externalId,
          ),
        );
        continue;
      }
      if (externalId != null) {
        _fail(_current.span, 'external-id requires a named import or export');
      }
      if (_matchWord('include')) {
        items.add(_parseWorldItem(WASIComponentWitWorldItemDirection.include));
        continue;
      }
      _skipWorldDeclaration();
    }
    _expectSymbol('}');
    return WASIComponentWitWorld(
      name: name.identifier,
      items: items,
      span: name.span,
    );
  }

  WASIComponentWitWorldItem _parseWorldItem(
    WASIComponentWitWorldItemDirection direction, {
    String? externalId,
  }) {
    final tokens = <_WitToken>[];
    final targetStart = _current.span;
    final renames = <String, String>{};
    var terminated = false;
    while (!_checkSymbol(';') && !_checkKind(_WitTokenKind.eof)) {
      if (_checkSymbol('}')) break;
      if (direction == WASIComponentWitWorldItemDirection.include &&
          _matchWord('with')) {
        _expectSymbol('{');
        while (!_checkSymbol('}') && !_checkKind(_WitTokenKind.eof)) {
          final from = _expectWord('included plain name');
          if (!_matchWord('as')) _fail(_current.span, "expected 'as'");
          final to = _expectWord('included plain name replacement');
          if (renames.containsKey(from.identifier)) {
            _fail(from.span, "duplicate include rename '${from.lexeme}'");
          }
          renames[from.identifier] = to.identifier;
          if (!_matchSymbol(',')) break;
        }
        _expectSymbol('}');
        _matchSymbol(';');
        terminated = true;
        break;
      }
      if (_checkSymbol('{')) {
        _advance();
        _skipBalancedBlock();
        _matchSymbol(';');
        terminated = true;
        break;
      }
      tokens.add(_current);
      _advance();
    }
    if (_matchSymbol(';')) terminated = true;
    if (tokens.isEmpty) {
      _fail(targetStart, 'expected world ${direction.name} target');
    }
    if (!terminated) {
      _fail(targetStart, 'unterminated world ${direction.name} target');
    }
    String? name;
    var targetTokens = tokens;
    if (direction != WASIComponentWitWorldItemDirection.include &&
        tokens.length >= 3 &&
        tokens[0].kind == _WitTokenKind.word &&
        tokens[1].lexeme == ':' &&
        (tokens[0].span.offset + tokens[0].span.length <
                tokens[1].span.offset ||
            tokens[1].span.offset + tokens[1].span.length <
                tokens[2].span.offset)) {
      name = tokens[0].identifier;
      // Function and inline-interface boundaries keep their existing compact
      // target spelling; only named interface references are expanded here.
      if (tokens[2].lexeme != 'interface' &&
          tokens[2].lexeme != 'func' &&
          tokens[2].lexeme != 'async') {
        targetTokens = tokens.sublist(2);
      }
    }
    if (externalId != null && name == null) {
      _fail(targetStart, 'external-id requires a plain binding name');
    }
    final target = WASIComponentWitTarget(
      text: targetTokens.map((token) => token.identifier).join(),
      span: targetTokens.first.span,
    );
    if (name == null &&
        target.text.contains(':') &&
        !target.text.contains('/')) {
      _fail(target.span, 'expected an interface path or a spaced plain label');
    }
    return WASIComponentWitWorldItem(
      direction: direction,
      name: name,
      target: target,
      span: targetStart,
      externalId: externalId,
      renames: Map<String, String>.unmodifiable(renames),
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

  String _normalizeResourceFunctionSignature(
    String signature,
    String? resourceName,
  ) {
    if (signature.startsWith('staticfunc')) {
      return signature.replaceFirst('staticfunc', 'func');
    }
    if (resourceName == null) {
      return signature;
    }
    return _withResourceReceiver(signature, resourceName);
  }

  String _withResourceReceiver(String signature, String resourceName) {
    if (!_isFunctionSignature(signature) || signature.contains('self:')) {
      return signature;
    }
    final receiver = 'self:borrow<$resourceName>';
    final open = signature.indexOf('(');
    if (open < 0) {
      return '$signature($receiver)';
    }
    var depth = 0;
    var angleDepth = 0;
    for (var i = open; i < signature.length; i++) {
      final code = signature.codeUnitAt(i);
      final char = String.fromCharCode(code);
      if (char == '<') {
        angleDepth++;
      } else if (char == '>' && angleDepth > 0) {
        angleDepth--;
      } else if (char == '(' && angleDepth == 0) {
        depth++;
      } else if (char == ')' && angleDepth == 0) {
        depth--;
        if (depth == 0) {
          final params = signature.substring(open + 1, i);
          final withReceiver = params.isEmpty ? receiver : '$receiver,$params';
          return '${signature.substring(0, open + 1)}$withReceiver'
              '${signature.substring(i)}';
        }
      }
    }
    return signature;
  }

  bool _isFunctionSignature(String signature) {
    return signature == 'func' ||
        signature.startsWith('func(') ||
        signature.contains('func(') ||
        signature.contains('asyncfunc(');
  }

  String? _parseAnnotations({required bool allowExternalId}) {
    String? externalId;
    while (_checkSymbol('@')) {
      final start = _current.span;
      _advance();
      final name = _expectWord('annotation name');
      if (name.lexeme == 'external-id') {
        if (!allowExternalId) {
          _fail(start, 'external-id is not valid on this declaration');
        }
        if (externalId != null) {
          _fail(start, 'duplicate external-id annotation');
        }
        _expectSymbol('(');
        if (!_checkKind(_WitTokenKind.string)) {
          _fail(_current.span, 'expected external-id string literal');
        }
        externalId = _current.lexeme;
        _advance();
        _expectSymbol(')');
      } else if (_matchSymbol('(')) {
        var depth = 1;
        while (depth > 0) {
          if (_checkKind(_WitTokenKind.eof)) {
            _fail(_current.span, 'unterminated WIT annotation');
          }
          if (_checkSymbol('(')) depth++;
          if (_checkSymbol(')')) depth--;
          _advance();
        }
      }
    }
    return externalId;
  }

  void _skipAnnotation() {
    _parseAnnotations(allowExternalId: false);
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

enum _WitTokenKind { word, string, symbol, eof }

final class _WitToken {
  const _WitToken({
    required this.kind,
    required this.lexeme,
    required this.span,
  });

  final _WitTokenKind kind;
  final String lexeme;
  final WASIComponentWitSpan span;

  String get identifier => kind == _WitTokenKind.word && lexeme.startsWith('%')
      ? lexeme.substring(1)
      : lexeme;
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
    if (code == 34) {
      return _stringToken(startOffset, startLine, startColumn);
    }
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

  _WitToken _stringToken(int startOffset, int startLine, int startColumn) {
    final start = _spanAtCurrent(1);
    Never fail(String message) {
      throw WASIComponentWitParseException(
        WASIComponentWitDiagnostic(
          sourceName: start.sourceName,
          line: start.line,
          column: start.column,
          message: message,
        ),
      );
    }

    final bytes = <int>[];
    _advanceChar();
    while (!_isAtEnd) {
      final code = _source.codeUnitAt(_offset);
      if (code == 34) {
        _advanceChar();
        String value;
        try {
          value = utf8.decode(bytes);
        } on FormatException {
          fail('WIT string literal is not valid UTF-8');
        }
        return _WitToken(
          kind: _WitTokenKind.string,
          lexeme: value,
          span: _span(startOffset, startLine, startColumn),
        );
      }
      if (code == 92) {
        _advanceChar();
        if (_isAtEnd) fail('unterminated WIT string literal');
        final escaped = _source.codeUnitAt(_offset);
        _advanceChar();
        const simple = <int, int>{
          110: 10,
          114: 13,
          116: 9,
          34: 34,
          39: 39,
          92: 92,
        };
        if (simple.containsKey(escaped)) {
          bytes.add(simple[escaped]!);
          continue;
        }
        if (escaped == 117 && _startsWith('{')) {
          _advanceChar();
          final digits = StringBuffer();
          var previousWasDigit = false;
          while (!_isAtEnd && !_startsWith('}')) {
            final digit = _source[_offset];
            if (digit == '_') {
              if (!previousWasDigit) fail('invalid Unicode escape separator');
              previousWasDigit = false;
            } else {
              if (int.tryParse(digit, radix: 16) == null) {
                fail('invalid Unicode escape in WIT string literal');
              }
              digits.write(digit);
              previousWasDigit = true;
            }
            _advanceChar();
          }
          if (_isAtEnd) {
            fail('unterminated Unicode escape in WIT string literal');
          }
          if (!previousWasDigit) fail('invalid Unicode escape separator');
          _advanceChar();
          final scalar = int.tryParse(digits.toString(), radix: 16);
          if (scalar == null ||
              scalar > 0x10ffff ||
              (scalar >= 0xd800 && scalar <= 0xdfff)) {
            fail('invalid Unicode scalar in WIT string literal');
          }
          bytes.addAll(utf8.encode(String.fromCharCode(scalar)));
          continue;
        }
        final high = int.tryParse(String.fromCharCode(escaped), radix: 16);
        final low = _isAtEnd ? null : int.tryParse(_source[_offset], radix: 16);
        if (high == null || low == null) fail('invalid WIT string escape');
        bytes.add(high * 16 + low);
        _advanceChar();
        continue;
      }
      if (code < 0x20 || code == 0x7f) {
        fail('unescaped control in WIT string literal');
      }
      var text = String.fromCharCode(code);
      _advanceChar();
      if (code >= 0xd800 && code <= 0xdbff) {
        if (_isAtEnd ||
            _source.codeUnitAt(_offset) < 0xdc00 ||
            _source.codeUnitAt(_offset) > 0xdfff) {
          fail('invalid Unicode scalar in WIT string literal');
        }
        text += _source[_offset];
        _advanceChar();
      } else if (code >= 0xdc00 && code <= 0xdfff) {
        fail('invalid Unicode scalar in WIT string literal');
      }
      bytes.addAll(utf8.encode(text));
    }
    fail('unterminated WIT string literal');
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
    // Check source characters while consuming them. Escaped string values are
    // decoded separately and may contain any Unicode scalar.
    if ((code < 0x20 && code != 9 && code != 10 && code != 13) ||
        (code >= 0x7f && code <= 0x9f) ||
        (code >= 0x202a && code <= 0x202e) ||
        (code >= 0x2066 && code <= 0x2069) ||
        code == 0x061c ||
        code == 0x200e ||
        code == 0x200f) {
      throw WASIComponentWitParseException(
        WASIComponentWitDiagnostic(
          sourceName: _sourceName,
          line: _line,
          column: _column,
          message:
              'forbidden raw WIT source character U+${code.toRadixString(16)}',
        ),
      );
    }
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
