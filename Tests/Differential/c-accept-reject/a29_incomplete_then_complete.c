struct N; struct N *head; struct N { struct N *next; int v; }; int f(void){ return head->v; }
