//
//  PMHTTPManagerTaskStateBox.m
//  PostmatesNetworking
//
//  Created by Kevin Ballard on 1/5/16.
//  Copyright © 2016 Postmates.
//
//  Licensed under the Apache License, Version 2.0 <LICENSE-APACHE or
//  http://www.apache.org/licenses/LICENSE-2.0> or the MIT license
//  <LICENSE-MIT or http://opensource.org/licenses/MIT>, at your
//  option. This file may not be copied, modified, or distributed
//  except according to those terms.
//

#import "PMHTTPManagerTaskStateBox.h"
#import <stdatomic.h>

// In order to implement network task swapping without any runtime penalty on the getter
// we're doing something a little unusual here. When we swap the tasks, we store the old
// task in a linked list, and the tasks are only released when the task state box deallocs.
// This ensures there's no threading issues with one thread reading the value, another thread
// replacing it, and then the first thread trying to retain and use the value it just read.
// Any thread interacting with the box has a retain on it, so the box can't dealloc until
// all threads have finished touching the task.
//
// The overall goal here is to implement network retrying without adding any locks (not even
// spinlocks) into the task.
typedef struct TaskList {
    // The next pointer does not need to be atomic because it will never be mutated once the
    // entry has been added to the linked list.
    struct TaskList * _Nullable next;
    const void * _Nonnull object;
} TaskList;

@implementation PMHTTPManagerTaskStateBox {
    atomic_uchar _state;
    _Atomic(const void * _Nonnull) _networkTask;
    _Atomic(TaskList * _Nullable) _taskListHead;
}

- (nonnull instancetype)initWithState:(PMHTTPManagerTaskStateBoxState)state networkTask:(nonnull NSURLSessionTask *)networkTask {
    if ((self = [super init])) {
        atomic_init(&_state, state);
        atomic_init(&_networkTask, (__bridge_retained const void *)networkTask);
    }
    return self;
}

- (void)dealloc {
    // We need to manually release _networkTask since it's masquearding as an atomic pointer.
    // We can do that just by transferring the retain count into ARC and throwing away the result.
    // Note that since we're in -dealloc only one thread owns us, and the obj-c runtime has issued
    // a full memory barrier already, but C11 atomics does not expose any equivalent to LLVM's
    // `unordered` ordering, so we have to use memory_order_relaxed anyway.
    (void)(__bridge_transfer id)atomic_load_explicit(&_networkTask, memory_order_relaxed);
    // Walk the linked list and release that too. The acquire here forms an edge with the release
    // in the compare_exchange operation.
    TaskList *head = atomic_load_explicit(&_taskListHead, memory_order_acquire);
    while (head) {
        (void)(__bridge_transfer id)head->object;
        head = head->next;
    }
}

- (PMHTTPManagerTaskStateBoxState)state {
    return atomic_load_explicit(&_state, memory_order_relaxed);
}

- (nonnull NSURLSessionTask *)networkTask {
    return (__bridge id)atomic_load_explicit(&_networkTask, memory_order_relaxed);
}

- (void)setNetworkTask:(nonnull NSURLSessionTask *)networkTask {
    // We swap a retained pointer into _networkTask and get the old retained pointer back.
    // We then push that onto the linked list, where dealloc will be able to find and release it.
    // Note that the order of the entries in the linked list is completely irrelevant, only the fact
    // that all removed tasks end up somewhere in it, so the memory ordering can be relaxed everywhere.
    const void *oldTask = atomic_exchange_explicit(&_networkTask, (__bridge_retained const void *)networkTask, memory_order_relaxed);
    TaskList *newHead = (TaskList *)malloc(sizeof(TaskList));
    newHead->object = oldTask;
    TaskList *oldHead = atomic_load_explicit(&_taskListHead, memory_order_relaxed);
    while (1) {
        newHead->next = oldHead;
        // The release on the store here forms an edge with the acquire in -dealloc.
        if (atomic_compare_exchange_weak_explicit(&_taskListHead, &oldHead, newHead, memory_order_release, memory_order_relaxed)) {
            return;
        }
    }
}

- (PMHTTPManagerTaskStateBoxResult)transitionStateTo:(PMHTTPManagerTaskStateBoxState)newState {
    switch (newState) {
        case PMHTTPManagerTaskStateBoxStateRunning: {
            // We can only transfer here from Processing (this is done when a failed task is retried).
            PMHTTPManagerTaskStateBoxState expected = PMHTTPManagerTaskStateBoxStateProcessing;
            _Bool success = atomic_compare_exchange_strong_explicit(&_state, &expected, newState, memory_order_relaxed, memory_order_relaxed);
            return (PMHTTPManagerTaskStateBoxResult){success || expected == newState, expected};
        }
        case PMHTTPManagerTaskStateBoxStateProcessing: {
            // We can only transition here from Running.
            PMHTTPManagerTaskStateBoxState expected = PMHTTPManagerTaskStateBoxStateRunning;
            _Bool success = atomic_compare_exchange_strong_explicit(&_state, &expected, newState, memory_order_relaxed, memory_order_relaxed);
            return (PMHTTPManagerTaskStateBoxResult){success || expected == newState, expected};
        }
        case PMHTTPManagerTaskStateBoxStateCanceled: {
            // Transition from Running or Processing.
            PMHTTPManagerTaskStateBoxState expected = PMHTTPManagerTaskStateBoxStateRunning;
            while (1) {
                if (atomic_compare_exchange_weak_explicit(&_state, &expected, newState, memory_order_relaxed, memory_order_relaxed)) {
                    return (PMHTTPManagerTaskStateBoxResult){true, expected};
                }
                switch (expected) {
                    case PMHTTPManagerTaskStateBoxStateRunning:
                    case PMHTTPManagerTaskStateBoxStateProcessing:
                        break;
                    case PMHTTPManagerTaskStateBoxStateCanceled:
                        return (PMHTTPManagerTaskStateBoxResult){true, expected};
                    case PMHTTPManagerTaskStateBoxStateCompleted:
                        return (PMHTTPManagerTaskStateBoxResult){false, expected};
                }
            }
        }
        case PMHTTPManagerTaskStateBoxStateCompleted: {
            // We can transition only from Processing.
            PMHTTPManagerTaskStateBoxState expected = PMHTTPManagerTaskStateBoxStateProcessing;
            _Bool success = atomic_compare_exchange_strong_explicit(&_state, &expected, newState, memory_order_relaxed, memory_order_relaxed);
            return (PMHTTPManagerTaskStateBoxResult){success || expected == newState, expected};
        }
    }
}
@end
