[[nodiscard]] int g(void); void f(int x){ switch(x){ case 1: x++; [[fallthrough]]; case 2: break; } }
