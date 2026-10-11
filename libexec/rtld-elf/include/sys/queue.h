#ifndef _SYS_QUEUE_H_
#define _SYS_QUEUE_H_
#define LIST_HEAD(name, type) struct name { struct type *lh_first; }
#define LIST_HEAD_INITIALIZER(head) { NULL }
#define LIST_ENTRY(type) struct { struct type *le_next; struct type **le_prev; }
#define LIST_INIT(head) do { (head)->lh_first = 0; } while (0)
#define LIST_FIRST(head) ((head)->lh_first)
#define LIST_EMPTY(head) (LIST_FIRST(head) == 0)
#define LIST_INSERT_HEAD(head, elm, field) do { (elm)->field.le_next = (head)->lh_first; if ((head)->lh_first) (head)->lh_first->field.le_prev = &(elm)->field.le_next; (head)->lh_first = (elm); (elm)->field.le_prev = &(head)->lh_first; } while (0)
#define LIST_INSERT_AFTER(listelm, elm, field) do { (elm)->field.le_next = (listelm)->field.le_next; if ((elm)->field.le_next) (elm)->field.le_next->field.le_prev = &(elm)->field.le_next; (listelm)->field.le_next = (elm); (elm)->field.le_prev = &(listelm)->field.le_next; } while (0)
#define LIST_REMOVE(elm, field) do { if ((elm)->field.le_next) (elm)->field.le_next->field.le_prev = (elm)->field.le_prev; *(elm)->field.le_prev = (elm)->field.le_next; } while (0)
#define LIST_FOREACH(var, head, field) for ((var) = LIST_FIRST(head); (var); (var) = (var)->field.le_next)
#define STAILQ_HEAD(name, type) struct name { struct type *stqh_first; struct type **stqh_last; }
#define STAILQ_HEAD_INITIALIZER(head) { NULL, &(head).stqh_first }
#define STAILQ_ENTRY(type) struct { struct type *stqe_next; }
#define STAILQ_INIT(head) do { (head)->stqh_first = 0; (head)->stqh_last = &(head)->stqh_first; } while (0)
#define STAILQ_FIRST(head) ((head)->stqh_first)
#define STAILQ_EMPTY(head) (STAILQ_FIRST(head) == 0)
#define STAILQ_NEXT(elm, field) ((elm)->field.stqe_next)
#define STAILQ_INSERT_HEAD(head, elm, field) do { (elm)->field.stqe_next = (head)->stqh_first; (head)->stqh_first = (elm); if ((elm)->field.stqe_next == 0) (head)->stqh_last = &(elm)->field.stqe_next; } while (0)
#define STAILQ_INSERT_TAIL(head, elm, field) do { (elm)->field.stqe_next = 0; *(head)->stqh_last = (elm); (head)->stqh_last = &(elm)->field.stqe_next; } while (0)
#define STAILQ_INSERT_AFTER(head, listelm, elm, field) do { (elm)->field.stqe_next = (listelm)->field.stqe_next; (listelm)->field.stqe_next = (elm); if ((elm)->field.stqe_next == 0) (head)->stqh_last = &(elm)->field.stqe_next; } while (0)
#define STAILQ_REMOVE_HEAD(head, field) do { (head)->stqh_first = (head)->stqh_first->field.stqe_next; if ((head)->stqh_first == 0) (head)->stqh_last = &(head)->stqh_first; } while (0)
#define STAILQ_REMOVE(head, elm, type, field) do { if ((head)->stqh_first == (elm)) { STAILQ_REMOVE_HEAD(head, field); } else { struct type *__c = (head)->stqh_first; while (__c->field.stqe_next != (elm)) __c = __c->field.stqe_next; __c->field.stqe_next = (elm)->field.stqe_next; if (__c->field.stqe_next == 0) (head)->stqh_last = &__c->field.stqe_next; } } while (0)
#define STAILQ_REVERSE(head, type, field) do { struct type *__c = (head)->stqh_first; struct type *__n; (head)->stqh_first = 0; (head)->stqh_last = &(head)->stqh_first; while (__c) { __n = __c->field.stqe_next; STAILQ_INSERT_HEAD(head, __c, field); __c = __n; } } while (0)
#define STAILQ_FOREACH(var, head, field) for ((var) = STAILQ_FIRST(head); (var); (var) = (var)->field.stqe_next)
#define TAILQ_HEAD(name, type) struct name { struct type *tqh_first; struct type **tqh_last; }
#define TAILQ_HEAD_INITIALIZER(head) { NULL, &(head).tqh_first }
#define TAILQ_ENTRY(type) struct { struct type *tqe_next; struct type **tqe_prev; }
#define TAILQ_INIT(head) do { (head)->tqh_first = 0; (head)->tqh_last = &(head)->tqh_first; } while (0)
#define TAILQ_FIRST(head) ((head)->tqh_first)
#define TAILQ_EMPTY(head) (TAILQ_FIRST(head) == 0)
#define TAILQ_NEXT(elm, field) ((elm)->field.tqe_next)
#define TAILQ_LAST(head, headname) (*(((struct headname *)((head)->tqh_last))->tqh_last))
#define TAILQ_PREV(elm, headname, field) (*(((struct headname *)((elm)->field.tqe_prev))->tqh_last))
#define TAILQ_INSERT_HEAD(head, elm, field) do { (elm)->field.tqe_next = (head)->tqh_first; if ((elm)->field.tqe_next) (elm)->field.tqe_next->field.tqe_prev = &(elm)->field.tqe_next; else (head)->tqh_last = &(elm)->field.tqe_next; (head)->tqh_first = (elm); (elm)->field.tqe_prev = &(head)->tqh_first; } while (0)
#define TAILQ_INSERT_TAIL(head, elm, field) do { (elm)->field.tqe_next = 0; (elm)->field.tqe_prev = (head)->tqh_last; *(head)->tqh_last = (elm); (head)->tqh_last = &(elm)->field.tqe_next; } while (0)
#define TAILQ_INSERT_AFTER(head, listelm, elm, field) do { (elm)->field.tqe_next = (listelm)->field.tqe_next; if ((elm)->field.tqe_next) (elm)->field.tqe_next->field.tqe_prev = &(elm)->field.tqe_next; else (head)->tqh_last = &(elm)->field.tqe_next; (listelm)->field.tqe_next = (elm); (elm)->field.tqe_prev = &(listelm)->field.tqe_next; } while (0)
#define TAILQ_REMOVE(head, elm, field) do { if ((elm)->field.tqe_next) (elm)->field.tqe_next->field.tqe_prev = (elm)->field.tqe_prev; else (head)->tqh_last = (elm)->field.tqe_prev; *(elm)->field.tqe_prev = (elm)->field.tqe_next; } while (0)
#define TAILQ_FOREACH(var, head, field) for ((var) = TAILQ_FIRST(head); (var); (var) = (var)->field.tqe_next)
#define TAILQ_INSERT_BEFORE(listelm, elm, field) do { (elm)->field.tqe_next = (listelm); (elm)->field.tqe_prev = (listelm)->field.tqe_prev; *(listelm)->field.tqe_prev = (elm); (listelm)->field.tqe_prev = &(elm)->field.tqe_next; } while (0)
#define STAILQ_FOREACH_SAFE(var, head, field, tvar) for ((var) = STAILQ_FIRST(head); (var) && ((tvar) = (var)->field.stqe_next, 1); (var) = (tvar))
#endif
