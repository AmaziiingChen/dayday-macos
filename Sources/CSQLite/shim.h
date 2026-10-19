#ifndef DAYDAY_CSQLITE_SHIM_H
#define DAYDAY_CSQLITE_SHIM_H

#include <sqlite3.h>

static inline sqlite3_destructor_type dayday_sqlite_transient(void) {
    return (sqlite3_destructor_type)-1;
}

#endif
