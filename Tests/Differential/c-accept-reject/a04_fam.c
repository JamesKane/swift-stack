struct S{ int n; int data[]; }; int f(struct S *s){ return s->data[s->n]; }
