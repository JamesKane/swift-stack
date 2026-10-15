[[nodiscard]] int g(void); [[deprecated("x")]] void h(void); void f([[maybe_unused]] int x){ [[fallthrough]]; switch(x){ case 1: x++; [[fallthrough]]; case 2: break; } }
