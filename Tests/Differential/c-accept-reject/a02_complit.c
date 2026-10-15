struct P{int x,y;}; int f(void){ struct P *p = &(struct P){1,2}; return p->y + (int[]){1,2,3}[1]; }
