package com.it_nomads.fluttersecurestorage;

import java.util.ArrayDeque;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.Consumer;

// Experimental only: not yet connected to plugin calls or any key reader.
final class AsyncStorageQueue {
    private static final class Turn {
        final Consumer<Runnable> operation;
        final Consumer<Throwable> onFailure;
        Turn(Consumer<Runnable> operation, Consumer<Throwable> onFailure) { this.operation = operation; this.onFailure = onFailure; }
    }
    private final ArrayDeque<Turn> pending = new ArrayDeque<>();
    private boolean active;
    private boolean pumping;

    void submit(Consumer<Runnable> operation) {
        submit(operation, ignored -> {});
    }
    void submit(Consumer<Runnable> operation, Consumer<Throwable> onFailure) {
        synchronized (this) { pending.addLast(new Turn(operation, onFailure)); }
        pump();
    }

    private void pump() {
        synchronized (this) {
            if (pumping) return;
            pumping = true;
        }
        for (;;) {
            Turn turn;
            synchronized (this) {
                if (active || pending.isEmpty()) { pumping = false; break; }
                active = true;
                turn = pending.removeFirst();
            }
            AtomicBoolean completed = new AtomicBoolean();
            Runnable done = () -> {
                if (!completed.compareAndSet(false, true)) return;
                synchronized (this) { active = false; }
                pump();
            };
            try { turn.operation.accept(done); }
            catch (RuntimeException error) {
                try { turn.onFailure.accept(error); } catch (RuntimeException ignored) { }
                finally { done.run(); }
            }
            catch (Error error) {
                done.run();
                synchronized (this) { pumping = false; }
                try { pump(); } catch (RuntimeException | Error next) { error.addSuppressed(next); }
                throw error;
            }
        }
    }
}
