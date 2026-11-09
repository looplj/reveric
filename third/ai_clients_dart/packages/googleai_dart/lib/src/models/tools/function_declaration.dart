import '../copy_with_sentinel.dart';

/// Structured representation of a function declaration.
class FunctionDeclaration {
  /// The name of the function.
  final String name;

  /// Description of what the function does.
  final String description;

  /// Parameters for the function as a JSON Schema object.
  final Map<String, dynamic>? parametersJsonSchema;

  /// Creates a [FunctionDeclaration].
  const FunctionDeclaration({
    required this.name,
    required this.description,
    this.parametersJsonSchema,
  });

  /// Creates a [FunctionDeclaration] from JSON.
  factory FunctionDeclaration.fromJson(Map<String, dynamic> json) =>
      FunctionDeclaration(
        name: json['name'] as String,
        description: json['description'] as String,
        parametersJsonSchema:
            json['parametersJsonSchema'] as Map<String, dynamic>?,
      );

  /// Converts to JSON.
  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    if (parametersJsonSchema != null)
      'parametersJsonSchema': parametersJsonSchema,
  };

  /// Creates a copy with replaced values.
  FunctionDeclaration copyWith({
    Object? name = unsetCopyWithValue,
    Object? description = unsetCopyWithValue,
    Object? parametersJsonSchema = unsetCopyWithValue,
  }) {
    return FunctionDeclaration(
      name: name == unsetCopyWithValue ? this.name : name! as String,
      description: description == unsetCopyWithValue
          ? this.description
          : description! as String,
      parametersJsonSchema: parametersJsonSchema == unsetCopyWithValue
          ? this.parametersJsonSchema
          : parametersJsonSchema as Map<String, dynamic>?,
    );
  }
}
