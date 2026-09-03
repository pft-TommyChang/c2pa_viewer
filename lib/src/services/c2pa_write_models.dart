class C2paWriteOptions {
  const C2paWriteOptions({required this.mode, required this.createNewFile});

  final C2paWriteMode mode;
  final bool createNewFile;
}

enum C2paWriteMode { add, replace, remove }
