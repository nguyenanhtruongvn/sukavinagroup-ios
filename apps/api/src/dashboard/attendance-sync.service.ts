import { Injectable, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import axios from 'axios';
import { PrismaService } from '../prisma/prisma.service';
import { ContentEventsService } from './content-events.service';

type WiseEyeRow = {
  userenrollnumber?: string | number;
  timestr?: string;
  source?: string;
  origintype?: string;
  machineno?: string | number;
  timedate?: string;
};

type WiseEyeResponse = {
  result?: boolean;
  total?: number;
  rows?: WiseEyeRow[];
  info?: string;
};

@Injectable()
export class AttendanceSyncService implements OnModuleInit, OnModuleDestroy {
  private timer?: NodeJS.Timeout;
  private syncing = false;
  private readonly syncingMonths = new Map<string, Promise<void>>();
  private readonly syncedMonths = new Set<string>();

  constructor(
    private readonly prisma: PrismaService,
    private readonly contentEvents: ContentEventsService,
  ) {}

  onModuleInit() {
    if (!process.env.WISEEYE_API_TOKEN || !process.env.WISEEYE_API_URL) {
      console.warn('WiseEye sync is disabled because its environment variables are missing.');
      return;
    }

    void this.pruneOldRecords().then(() => this.syncToday());
    const intervalMs = Math.max(5000, Number(process.env.WISEEYE_SYNC_INTERVAL_MS ?? 10000));
    this.timer = setInterval(() => void this.syncToday(), intervalMs);
  }

  onModuleDestroy() {
    if (this.timer) clearInterval(this.timer);
  }

  private async syncToday() {
    if (this.syncing) return;
    this.syncing = true;
    try {
      await this.fetchAndPersist('getrecordtoday', {});
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      console.error(`WiseEye attendance sync failed: ${message}`);
    } finally {
      this.syncing = false;
    }
  }

  async syncMonth(requestedMonth?: string) {
    const month = requestedMonth || this.vietnamDate().slice(0, 7);
    if (!/^\d{4}-(0[1-9]|1[0-2])$/.test(month) || !this.allowedMonths().includes(month) || this.syncedMonths.has(month)) return;
    const inProgress = this.syncingMonths.get(month);
    if (inProgress) return inProgress;

    const task = (async () => {
      const [year, monthNumber] = month.split('-').map(Number);
      const today = this.vietnamDate();
      const enddate = today.startsWith(month)
        ? this.addDays(today, 1)
        : `${monthNumber === 12 ? year + 1 : year}-${String((monthNumber % 12) + 1).padStart(2, '0')}-01`;
      await this.fetchAndPersist('getrecordbyperiodoftime', {
        startdate: `${month}-01`,
        enddate,
        userenrollnumber: '',
      });
      this.syncedMonths.add(month);
    })().finally(() => this.syncingMonths.delete(month));
    this.syncingMonths.set(month, task);
    return task;
  }

  private async fetchAndPersist(apiId: string, parameters: Record<string, string>) {
    const response = await axios.post<WiseEyeResponse>(
      `${process.env.WISEEYE_API_URL}?id=${apiId}`,
      { apitoken: process.env.WISEEYE_API_TOKEN, ...parameters },
      {
        timeout: 60000,
        headers: { 'Content-Type': 'application/json' },
        // WiseEye Proxy emits a folded CSP header that strict Node parsers reject.
        insecureHTTPParser: true,
      },
    );
    const payload = typeof response.data === 'string' ? JSON.parse(response.data) : response.data;
    if (!payload.result) throw new Error(payload.info || 'WiseEye returned result=false');

    const allowedMonths = new Set(this.allowedMonths());
    const rows = (payload.rows ?? []).flatMap((row) => {
      const userEnrollNumber = String(row.userenrollnumber ?? '').trim();
      const punchedAt = this.parseVietnamDateTime(row.timestr);
      const attendanceDate = row.timedate || row.timestr?.slice(0, 10) || '';
      if (!userEnrollNumber || !punchedAt || !allowedMonths.has(attendanceDate.slice(0, 7))) return [];
      return [{
        userEnrollNumber,
        punchedAt,
        source: String(row.source ?? 'UNKNOWN'),
        originType: row.origintype ? String(row.origintype) : null,
        machineNo: Number(row.machineno ?? 0) || 0,
        attendanceDate,
      }];
    });

    let insertedCount = 0;
    for (let index = 0; index < rows.length; index += 5000) {
      const inserted = await this.prisma.attendanceRecord.createMany({
        data: rows.slice(index, index + 5000),
        skipDuplicates: true,
      });
      insertedCount += inserted.count;
    }
    if (insertedCount > 0) this.contentEvents.notify('attendance_changed');
  }

  private vietnamDate() {
    return new Intl.DateTimeFormat('en-CA', {
      timeZone: 'Asia/Ho_Chi_Minh',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
    }).format(new Date());
  }

  private allowedMonths() {
    const currentMonth = this.vietnamDate().slice(0, 7);
    const [year, month] = currentMonth.split('-').map(Number);
    const previous = new Date(Date.UTC(year, month - 2, 1));
    const previousMonth = `${previous.getUTCFullYear()}-${String(previous.getUTCMonth() + 1).padStart(2, '0')}`;
    return [currentMonth, previousMonth];
  }

  private async pruneOldRecords() {
    const previousMonth = this.allowedMonths()[1];
    const deleted = await this.prisma.attendanceRecord.deleteMany({
      where: { attendanceDate: { lt: `${previousMonth}-01` } },
    });
    if (deleted.count > 0) {
      console.log(`Removed ${deleted.count} attendance records older than ${previousMonth}.`);
    }
  }

  private addDays(value: string, days: number) {
    const date = new Date(`${value}T00:00:00Z`);
    date.setUTCDate(date.getUTCDate() + days);
    return date.toISOString().slice(0, 10);
  }

  private parseVietnamDateTime(value?: string) {
    if (!value) return null;
    const normalized = value.trim().replace(' ', 'T');
    const parsed = new Date(`${normalized}+07:00`);
    return Number.isNaN(parsed.getTime()) ? null : parsed;
  }
}
