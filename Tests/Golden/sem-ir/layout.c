// Struct layout: packed structures, member alignment, `#pragma pack` (with push and pop) and bit-fields
// placed without padding under it.
struct __attribute__((packed)) Packed { char c; int i; _Alignas(8) short s; };
#pragma pack(push, 2)
struct Two { char c; double d; int b : 3; int e : 30; };
#pragma pack(push, 1)
struct One { char c; long l; };
#pragma pack(pop)
struct StillTwo { char c; int i; };
#pragma pack(pop)
struct Normal { char c; int i; };

struct Packed packed = { 1, 2, 3 };
struct Two two = { 1, 2.0, -1, 5 };
struct One one = { 1, 2 };
struct StillTwo still = { 1, 2 };
struct Normal normal = { 1, 2 };
