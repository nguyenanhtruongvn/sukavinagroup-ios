import { ArgumentsHost, Catch, ExceptionFilter, HttpException, Injectable } from '@nestjs/common';
import { Response, Request } from 'express';
import { LogsService } from '../logs/logs.service';

@Catch()
@Injectable()
export class AllExceptionsFilter implements ExceptionFilter {
  constructor(private readonly logsService: LogsService) {}

  catch(exception: unknown, host: ArgumentsHost) {
    const ctx = host.switchToHttp();
    const response = ctx.getResponse<Response>();
    const request = ctx.getRequest<Request>();
    const status = exception instanceof HttpException ? exception.getStatus() : 500;
    const message =
      exception instanceof Error ? exception.message : 'Unknown error';
    void this.logsService.write(
      'error',
      'exception',
      `${request.method} ${request.originalUrl} -> ${status}: ${message}`,
      JSON.stringify({
        path: request.originalUrl,
        method: request.method,
      }),
    );
    response.status(status).json({
      statusCode: status,
      message,
    });
  }
}
