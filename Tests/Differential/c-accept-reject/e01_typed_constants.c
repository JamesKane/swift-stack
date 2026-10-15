static_assert(sizeof(1ull) == 8 && sizeof(0xFFFFFFFF) == 4 && sizeof(2147483648) == 8 && !(-1 < 0u));
static_assert((unsigned char)300 == 44 && (signed char)200 == -56 && sizeof("abc") == 4 && sizeof(L"ab") == 12);
static_assert(sizeof((char[]){"hi"}) == 3 && sizeof(1.0f) == 4 && sizeof('a') == 4);
