_Atomic int x; _Atomic(long) y; int f(void){ return x + (int)y; }
