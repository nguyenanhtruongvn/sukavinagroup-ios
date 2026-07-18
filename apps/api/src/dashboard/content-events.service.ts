import { Injectable, MessageEvent } from '@nestjs/common';
import { interval, map, merge, Observable, startWith, Subject } from 'rxjs';

@Injectable()
export class ContentEventsService {
  private readonly changes = new Subject<string>();

  notify(type = 'content_changed') {
    this.changes.next(type);
  }

  stream(): Observable<MessageEvent> {
    const updates = this.changes.pipe(
      startWith('connected'),
      map((type) => ({ data: { type } })),
    );
    const heartbeat = interval(15000).pipe(
      map(() => ({ data: { type: 'heartbeat' } })),
    );
    return merge(updates, heartbeat);
  }
}
