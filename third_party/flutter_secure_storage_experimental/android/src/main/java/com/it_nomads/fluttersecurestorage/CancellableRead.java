package com.it_nomads.fluttersecurestorage;

import java.util.concurrent.atomic.AtomicInteger;

/** Cancellation is cooperative: an already started read cannot be interrupted. */
public final class CancellableRead {
    // 0 = queued, 1 = reading, 2 = delivery claimed, 3 = cancelled, 4 = delivered.
    private final AtomicInteger state = new AtomicInteger();

    /** Never waits for a read or callback; false means delivery was already claimed. */
    public boolean cancel() {
        for (;;) {
            int current = state.get();
            if (current == 3) return true;
            if (current >= 2) return false;
            if (state.compareAndSet(current, 3)) return true;
        }
    }

    boolean tryStart() { return state.compareAndSet(0, 1); }

    void deliver(Runnable callback) {
        if (!state.compareAndSet(1, 2)) return;
        try { callback.run(); }
        finally { state.set(4); }
    }
}
