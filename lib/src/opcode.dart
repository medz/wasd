abstract final class Opcodes {
  static const int unreachable = 0x00;
  static const int nop = 0x01;

  static const int block = 0x02;
  static const int loop = 0x03;
  static const int if_ = 0x04;
  static const int else_ = 0x05;

  static const int end = 0x0b;
  static const int br = 0x0c;
  static const int brIf = 0x0d;
  static const int brTable = 0x0e;
  static const int return_ = 0x0f;

  static const int call = 0x10;
  static const int callIndirect = 0x11;
  static const int returnCall = 0x12;
  static const int returnCallIndirect = 0x13;
  static const int callRef = 0x14;
  static const int returnCallRef = 0x15;

  static const int drop = 0x1a;
  static const int select = 0x1b;
  static const int selectT = 0x1c;

  static const int localGet = 0x20;
  static const int localSet = 0x21;
  static const int localTee = 0x22;
  static const int globalGet = 0x23;
  static const int globalSet = 0x24;
  static const int tableGet = 0x25;
  static const int tableSet = 0x26;

  static const int i32Load = 0x28;
  static const int i64Load = 0x29;
  static const int f32Load = 0x2a;
  static const int f64Load = 0x2b;
  static const int i32Load8S = 0x2c;
  static const int i32Load8U = 0x2d;
  static const int i32Load16S = 0x2e;
  static const int i32Load16U = 0x2f;
  static const int i64Load8S = 0x30;
  static const int i64Load8U = 0x31;
  static const int i64Load16S = 0x32;
  static const int i64Load16U = 0x33;
  static const int i64Load32S = 0x34;
  static const int i64Load32U = 0x35;
  static const int i32Store = 0x36;
  static const int i64Store = 0x37;
  static const int f32Store = 0x38;
  static const int f64Store = 0x39;
  static const int i32Store8 = 0x3a;
  static const int i32Store16 = 0x3b;
  static const int i64Store8 = 0x3c;
  static const int i64Store16 = 0x3d;
  static const int i64Store32 = 0x3e;

  static const int memorySize = 0x3f;
  static const int memoryGrow = 0x40;

  static const int i32Const = 0x41;
  static const int i64Const = 0x42;
  static const int f32Const = 0x43;
  static const int f64Const = 0x44;

  static const int i32Eqz = 0x45;
  static const int i32Eq = 0x46;
  static const int i32Ne = 0x47;
  static const int i32LtS = 0x48;
  static const int i32LtU = 0x49;
  static const int i32GtS = 0x4a;
  static const int i32GtU = 0x4b;
  static const int i32LeS = 0x4c;
  static const int i32LeU = 0x4d;
  static const int i32GeS = 0x4e;
  static const int i32GeU = 0x4f;

  static const int i64Eqz = 0x50;
  static const int i64Eq = 0x51;
  static const int i64Ne = 0x52;
  static const int i64LtS = 0x53;
  static const int i64LtU = 0x54;
  static const int i64GtS = 0x55;
  static const int i64GtU = 0x56;
  static const int i64LeS = 0x57;
  static const int i64LeU = 0x58;
  static const int i64GeS = 0x59;
  static const int i64GeU = 0x5a;

  static const int f32Eq = 0x5b;
  static const int f32Ne = 0x5c;
  static const int f32Lt = 0x5d;
  static const int f32Gt = 0x5e;
  static const int f32Le = 0x5f;
  static const int f32Ge = 0x60;

  static const int f64Eq = 0x61;
  static const int f64Ne = 0x62;
  static const int f64Lt = 0x63;
  static const int f64Gt = 0x64;
  static const int f64Le = 0x65;
  static const int f64Ge = 0x66;

  static const int i32Clz = 0x67;
  static const int i32Ctz = 0x68;
  static const int i32Popcnt = 0x69;
  static const int i32Add = 0x6a;
  static const int i32Sub = 0x6b;
  static const int i32Mul = 0x6c;
  static const int i32DivS = 0x6d;
  static const int i32DivU = 0x6e;
  static const int i32RemS = 0x6f;
  static const int i32RemU = 0x70;
  static const int i32And = 0x71;
  static const int i32Or = 0x72;
  static const int i32Xor = 0x73;
  static const int i32Shl = 0x74;
  static const int i32ShrS = 0x75;
  static const int i32ShrU = 0x76;
  static const int i32Rotl = 0x77;
  static const int i32Rotr = 0x78;

  static const int i64Clz = 0x79;
  static const int i64Ctz = 0x7a;
  static const int i64Popcnt = 0x7b;
  static const int i64Add = 0x7c;
  static const int i64Sub = 0x7d;
  static const int i64Mul = 0x7e;
  static const int i64DivS = 0x7f;
  static const int i64DivU = 0x80;
  static const int i64RemS = 0x81;
  static const int i64RemU = 0x82;
  static const int i64And = 0x83;
  static const int i64Or = 0x84;
  static const int i64Xor = 0x85;
  static const int i64Shl = 0x86;
  static const int i64ShrS = 0x87;
  static const int i64ShrU = 0x88;
  static const int i64Rotl = 0x89;
  static const int i64Rotr = 0x8a;

  static const int f32Abs = 0x8b;
  static const int f32Neg = 0x8c;
  static const int f32Ceil = 0x8d;
  static const int f32Floor = 0x8e;
  static const int f32Trunc = 0x8f;
  static const int f32Nearest = 0x90;
  static const int f32Sqrt = 0x91;
  static const int f32Add = 0x92;
  static const int f32Sub = 0x93;
  static const int f32Mul = 0x94;
  static const int f32Div = 0x95;
  static const int f32Min = 0x96;
  static const int f32Max = 0x97;
  static const int f32CopySign = 0x98;

  static const int f64Abs = 0x99;
  static const int f64Neg = 0x9a;
  static const int f64Ceil = 0x9b;
  static const int f64Floor = 0x9c;
  static const int f64Trunc = 0x9d;
  static const int f64Nearest = 0x9e;
  static const int f64Sqrt = 0x9f;
  static const int f64Add = 0xa0;
  static const int f64Sub = 0xa1;
  static const int f64Mul = 0xa2;
  static const int f64Div = 0xa3;
  static const int f64Min = 0xa4;
  static const int f64Max = 0xa5;
  static const int f64CopySign = 0xa6;

  static const int i32WrapI64 = 0xa7;
  static const int i32TruncF32S = 0xa8;
  static const int i32TruncF32U = 0xa9;
  static const int i32TruncF64S = 0xaa;
  static const int i32TruncF64U = 0xab;
  static const int i64ExtendI32S = 0xac;
  static const int i64ExtendI32U = 0xad;
  static const int i64TruncF32S = 0xae;
  static const int i64TruncF32U = 0xaf;
  static const int i64TruncF64S = 0xb0;
  static const int i64TruncF64U = 0xb1;
  static const int f32ConvertI32S = 0xb2;
  static const int f32ConvertI32U = 0xb3;
  static const int f32ConvertI64S = 0xb4;
  static const int f32ConvertI64U = 0xb5;
  static const int f32DemoteF64 = 0xb6;
  static const int f64ConvertI32S = 0xb7;
  static const int f64ConvertI32U = 0xb8;
  static const int f64ConvertI64S = 0xb9;
  static const int f64ConvertI64U = 0xba;
  static const int f64PromoteF32 = 0xbb;
  static const int i32ReinterpretF32 = 0xbc;
  static const int i64ReinterpretF64 = 0xbd;
  static const int f32ReinterpretI32 = 0xbe;
  static const int f64ReinterpretI64 = 0xbf;

  static const int i32Extend8S = 0xc0;
  static const int i32Extend16S = 0xc1;
  static const int i64Extend8S = 0xc2;
  static const int i64Extend16S = 0xc3;
  static const int i64Extend32S = 0xc4;

  static const int refNull = 0xd0;
  static const int refIsNull = 0xd1;
  static const int refFunc = 0xd2;
  static const int refEq = 0xd3;
  static const int refAsNonNull = 0xd4;
  static const int brOnNull = 0xd5;
  static const int brOnNonNull = 0xd6;

  // 0xFC prefixed pseudo-opcodes encoded as (0xFC00 | subopcode)
  static const int i32TruncSatF32S = 0xfc00;
  static const int i32TruncSatF32U = 0xfc01;
  static const int i32TruncSatF64S = 0xfc02;
  static const int i32TruncSatF64U = 0xfc03;
  static const int i64TruncSatF32S = 0xfc04;
  static const int i64TruncSatF32U = 0xfc05;
  static const int i64TruncSatF64S = 0xfc06;
  static const int i64TruncSatF64U = 0xfc07;
  static const int memoryInit = 0xfc08;
  static const int dataDrop = 0xfc09;
  static const int memoryCopy = 0xfc0a;
  static const int memoryFill = 0xfc0b;
  static const int tableInit = 0xfc0c;
  static const int elemDrop = 0xfc0d;
  static const int tableCopy = 0xfc0e;
  static const int tableGrow = 0xfc0f;
  static const int tableSize = 0xfc10;
  static const int tableFill = 0xfc11;
  static const int i64Add128 = 0xfc13;
  static const int i64Sub128 = 0xfc14;
  static const int i64MulWideS = 0xfc15;
  static const int i64MulWideU = 0xfc16;

  // 0xFB prefixed pseudo-opcodes encoded as (0xFB00 | subopcode)
  static const int structNew = 0xfb00;
  static const int structNewDefault = 0xfb01;
  static const int structGetU = 0xfb02;
  static const int structGetS = 0xfb03;
  static const int arrayNew = 0xfb06;
  static const int arrayNewDefault = 0xfb07;
  static const int arrayNewFixed = 0xfb08;
  static const int arrayNewData = 0xfb09;
  static const int arrayNewElem = 0xfb0a;
  static const int arrayGet = 0xfb0b;
  static const int arrayGetS = 0xfb0c;
  static const int arrayGetU = 0xfb0d;
  static const int arraySet = 0xfb0e;
  static const int arrayLen = 0xfb0f;
  static const int arrayFill = 0xfb10;
  static const int arrayCopy = 0xfb11;
  static const int arrayInitData = 0xfb12;
  static const int arrayInitElem = 0xfb13;
  static const int refTest = 0xfb14;
  static const int refTestNullable = 0xfb15;
  static const int refCast = 0xfb16;
  static const int refCastNullable = 0xfb17;
  static const int brOnCast = 0xfb18;
  static const int brOnCastFail = 0xfb19;
  static const int anyConvertExtern = 0xfb1a;
  static const int externConvertAny = 0xfb1b;
  static const int refI31 = 0xfb1c;
  static const int i31GetS = 0xfb1d;
  static const int i31GetU = 0xfb1e;
  static const int structNewDesc = 0xfb20;
  static const int structNewDefaultDesc = 0xfb21;
  static const int refGetDesc = 0xfb22;
  static const int refCastDesc = 0xfb23;
  static const int refCastDescEq = 0xfb24;
  static const int brOnCastDescEq = 0xfb25;
  static const int brOnCastDescEqFail = 0xfb26;

  // 0xFE prefixed pseudo-opcodes encoded as (0xFE00 | subopcode)
  static const int memoryAtomicNotify = 0xfe00;
  static const int memoryAtomicWait32 = 0xfe01;
  static const int memoryAtomicWait64 = 0xfe02;
  static const int atomicFence = 0xfe03;

  static const int i32AtomicLoad = 0xfe10;
  static const int i64AtomicLoad = 0xfe11;
  static const int i32AtomicLoad8U = 0xfe12;
  static const int i32AtomicLoad16U = 0xfe13;
  static const int i64AtomicLoad8U = 0xfe14;
  static const int i64AtomicLoad16U = 0xfe15;
  static const int i64AtomicLoad32U = 0xfe16;

  static const int i32AtomicStore = 0xfe17;
  static const int i64AtomicStore = 0xfe18;
  static const int i32AtomicStore8 = 0xfe19;
  static const int i32AtomicStore16 = 0xfe1a;
  static const int i64AtomicStore8 = 0xfe1b;
  static const int i64AtomicStore16 = 0xfe1c;
  static const int i64AtomicStore32 = 0xfe1d;

  static const int i32AtomicRmwAdd = 0xfe1e;
  static const int i64AtomicRmwAdd = 0xfe1f;
  static const int i32AtomicRmw8AddU = 0xfe20;
  static const int i32AtomicRmw16AddU = 0xfe21;
  static const int i64AtomicRmw8AddU = 0xfe22;
  static const int i64AtomicRmw16AddU = 0xfe23;
  static const int i64AtomicRmw32AddU = 0xfe24;

  static const int i32AtomicRmwSub = 0xfe25;
  static const int i64AtomicRmwSub = 0xfe26;
  static const int i32AtomicRmw8SubU = 0xfe27;
  static const int i32AtomicRmw16SubU = 0xfe28;
  static const int i64AtomicRmw8SubU = 0xfe29;
  static const int i64AtomicRmw16SubU = 0xfe2a;
  static const int i64AtomicRmw32SubU = 0xfe2b;

  static const int i32AtomicRmwAnd = 0xfe2c;
  static const int i64AtomicRmwAnd = 0xfe2d;
  static const int i32AtomicRmw8AndU = 0xfe2e;
  static const int i32AtomicRmw16AndU = 0xfe2f;
  static const int i64AtomicRmw8AndU = 0xfe30;
  static const int i64AtomicRmw16AndU = 0xfe31;
  static const int i64AtomicRmw32AndU = 0xfe32;

  static const int i32AtomicRmwOr = 0xfe33;
  static const int i64AtomicRmwOr = 0xfe34;
  static const int i32AtomicRmw8OrU = 0xfe35;
  static const int i32AtomicRmw16OrU = 0xfe36;
  static const int i64AtomicRmw8OrU = 0xfe37;
  static const int i64AtomicRmw16OrU = 0xfe38;
  static const int i64AtomicRmw32OrU = 0xfe39;

  static const int i32AtomicRmwXor = 0xfe3a;
  static const int i64AtomicRmwXor = 0xfe3b;
  static const int i32AtomicRmw8XorU = 0xfe3c;
  static const int i32AtomicRmw16XorU = 0xfe3d;
  static const int i64AtomicRmw8XorU = 0xfe3e;
  static const int i64AtomicRmw16XorU = 0xfe3f;
  static const int i64AtomicRmw32XorU = 0xfe40;

  static const int i32AtomicRmwXchg = 0xfe41;
  static const int i64AtomicRmwXchg = 0xfe42;
  static const int i32AtomicRmw8XchgU = 0xfe43;
  static const int i32AtomicRmw16XchgU = 0xfe44;
  static const int i64AtomicRmw8XchgU = 0xfe45;
  static const int i64AtomicRmw16XchgU = 0xfe46;
  static const int i64AtomicRmw32XchgU = 0xfe47;

  static const int i32AtomicRmwCmpxchg = 0xfe48;
  static const int i64AtomicRmwCmpxchg = 0xfe49;
  static const int i32AtomicRmw8CmpxchgU = 0xfe4a;
  static const int i32AtomicRmw16CmpxchgU = 0xfe4b;
  static const int i64AtomicRmw8CmpxchgU = 0xfe4c;
  static const int i64AtomicRmw16CmpxchgU = 0xfe4d;
  static const int i64AtomicRmw32CmpxchgU = 0xfe4e;
}
