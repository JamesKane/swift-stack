enum E { A }; enum E f(void); unsigned f(void);
enum Big { B = 0x100000000 }; static_assert(sizeof(enum Big) == 8);
enum Fixed : unsigned char { C = 255 }; static_assert(sizeof(enum Fixed) == 1);
