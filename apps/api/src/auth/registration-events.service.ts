import { Injectable, MessageEvent } from '@nestjs/common';
import { interval, map, merge, Observable, startWith, Subject } from 'rxjs';
import { assertPermission, AuthUser } from './permissions';

@Injectable()
export class RegistrationEventsService {
  private readonly changes = new Subject<void>();

  notify() {
    this.changes.next();
  }

  stream(user: AuthUser): Observable<MessageEvent> {
    assertPermission(user, 'accounts.manage');
    const updates = this.changes.pipe(
      startWith(undefined),
      map(() => ({ data: { type: 'registration_changed' } })),
    );
    const heartbeat = interval(15000).pipe(
      map(() => ({ data: { type: 'heartbeat' } })),
    );
    return merge(updates, heartbeat);
  }
}
