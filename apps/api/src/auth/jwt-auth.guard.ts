import { ExecutionContext, ForbiddenException, Injectable } from '@nestjs/common';
import { AuthGuard } from '@nestjs/passport';

@Injectable()
export class JwtAuthGuard extends AuthGuard('jwt') {
  async canActivate(context: ExecutionContext) {
    const authenticated = await super.canActivate(context);
    if (!authenticated) return false;
    const request = context.switchToHttp().getRequest<{
      user?: { accountType?: string };
      originalUrl?: string;
    }>();
    const path = request.originalUrl?.split('?')[0] ?? '';
    if (request.user?.accountType === 'DEMO' && path.includes('/admin/')) {
      throw new ForbiddenException('Tài khoản demo không được truy cập khu vực quản trị.');
    }
    if (request.user?.accountType === 'CANTEEN') {
      const allowed = path.endsWith('/auth/me') || path.endsWith('/me/menu/scan');
      if (!allowed && request.user?.accountType !== 'DEMO') throw new ForbiddenException('Tài khoản nhà ăn chỉ được sử dụng chức năng quét mã suất ăn.');
    }
    return true;
  }
}
