package com.it_nomads.fluttersecurestorage;

import java.util.concurrent.atomic.AtomicBoolean;

/** At most one reader turn may be outstanding in the shared plugin queue. */
final class ReadAdmission {
    private final AtomicBoolean occupied = new AtomicBoolean();
    boolean tryAcquire() { return occupied.compareAndSet(false, true); }
    void release() { occupied.set(false); }
}
