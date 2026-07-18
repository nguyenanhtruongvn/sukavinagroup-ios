import {
  Injectable,
  NestMiddleware,
} from '@nestjs/common';
import { Request, Response, NextFunction } from 'express';
import { LogsService } from '../logs/logs.service';

@Injectable()
export class RequestLoggingMiddleware implements NestMiddleware {
  constructor(private readonly logsService: LogsService) {}

  use(req: Request, res: Response, next: NextFunction) {
    const startedAt = Date.now();
    res.on('finish', () => {
      void this.logsService.write(
        res.statusCode >= 400 ? 'warn' : 'info',
        'http',
        `${req.method} ${req.originalUrl} -> ${res.statusCode}`,
        JSON.stringify({ durationMs: Date.now() - startedAt }),
      );
    });
    next();
  }
}
