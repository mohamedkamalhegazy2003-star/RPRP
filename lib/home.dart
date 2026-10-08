import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' as intl;

import 'auth.dart';
import 'db.dart';
import 'finance.dart';
import 'map_picker.dart';
import 'pdf_export.dart';
import 'property_detail.dart';
import 'property_form.dart';
import 'report_screen.dart';
import 'security.dart';
import 'smooth.dart';
import 'utils.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  bool _loading = true;
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _payments = [];
  Map<int, Map<String, List<String>>> _atts = {};
  bool _alertsShown = false;
  String _query = '';
  String? _filter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await DB.all();
    final pays = await DB.payments();
    final atts = await DB.attachmentMap();
    if (!mounted) return;
    setState(() {
      _items = data;
      _payments = pays;
      _atts = atts;
      _loading = false;
    });
    if (!_alertsShown && _alerts.isNotEmpty) {
      _alertsShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showAlerts();
      });
    }
  }

  List<Map<String, dynamic>> get _alerts => computeAlerts(_items);

  Future<void> _openForm([Map<String, dynamic>? item]) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => PropertyFormScreen(property: item)),
    );
    if (saved == true) {
      await _load();
      if (mounted) toast(context, item == null ? 'تمت إضافة العقار' : 'تم تحديث العقار');
    }
  }

  Future<void> _openDetail(Map<String, dynamic> item) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => PropertyDetailScreen(propertyId: item['id'] as int)),
    );
    await _load();
  }

  Future<void> _openSettings() async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
    await _load();
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف العقار'),
        content: Text('هل تريد حذف "${item['name']}" نهائياً؟\n(سجل الإيصالات القديمة يبقى محفوظاً)'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('حذف')),
        ],
      ),
    );
    if (ok == true && mounted && await biometricAuth(context, 'تأكيد حذف العقار')) {
      final id = item['id'] as int;
      final files = [...?_atts[id]?['id'], ...?_atts[id]?['contract']];
      await DB.delete(id);
      for (final f in files) {
        try {
          await File(f).delete();
        } catch (_) {}
      }
      await _load();
      if (mounted) toast(context, 'تم حذف العقار');
    }
  }

  Future<void> _whatsapp(Map<String, dynamic> item, String type) async {
    final a = fmt(totalDue(item));
    final t = item['tenant_name'];
    final n = item['name'];
    final d = parseDue(item['due_date']);
    final dueStr = d == null ? '' : ' (تاريخ الاستحقاق ${fmtDate(d)})';
    String msg;
    if (type == 'reminder') {
      msg = 'أهلاً $t، نود تذكيرك بقرب موعد سداد إيجار $n وقيمته الإجمالية $a$dueStr.';
    } else if (type == 'late') {
      msg = 'عزيزي $t، نود إحاطتكم بتأخر سداد مستحقات $n وقيمتها $a$dueStr. نرجو السداد في أقرب وقت.';
    } else {
      msg = 'شكراً لك $t على التزامك بسداد مستحقات $n.';
    }
    await launchWa(context, phoneOf(item), msg);
  }

  Future<void> _pay(Map<String, dynamic> item) async {
    final ok = await showPayDialog(context, item);
    if (ok) await _load();
  }

  List<Map<String, dynamic>> get _filtered {
    return _items.where((i) {
      if (_filter != null && effStatus(i) != _filter) return false;
      if (_query.isEmpty) return true;
      final q = _query.toLowerCase();
      return '${i['name']} ${i['tenant_name']} ${i['address']} ${i['location']}'
          .toLowerCase()
          .contains(q);
    }).toList();
  }

  // ---------------- التنبيهات ----------------
  void _showAlerts() {
    final list = _alerts;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('التنبيهات (${list.length})',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              if (list.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(24), child: Text('لا توجد تنبيهات حالياً'))
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, k) {
                      final it = list[k];
                      final d = daysUntilDue(it);
                      final late = d == null || d < 0;
                      final c = late ? const Color(0xFFC62828) : const Color(0xFFEF6C00);
                      final dd = parseDue(it['due_date']);
                      String sub;
                      if (d == null || dd == null) {
                        sub = 'متأخر (لم يُحدد تاريخ استحقاق)';
                      } else if (d < 0) {
                        sub = 'متأخر منذ ${fmtDate(dd)} (${-d} يوم)';
                      } else if (d == 0) {
                        sub = 'يستحق اليوم';
                      } else {
                        sub = 'يستحق ${fmtDate(dd)} (بعد $d يوم)';
                      }
                      return ListTile(
                        isThreeLine: true,
                        leading: CircleAvatar(
                          backgroundColor: c.withAlpha(30),
                          child: Icon(late ? Icons.warning_amber_rounded : Icons.schedule,
                              color: c),
                        ),
                        title: Text('${it['tenant_name']} - ${it['name']}',
                            style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text('$sub\nالمستحق: ${fmt(totalDue(it))}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'واتساب',
                              icon: const Icon(Icons.chat, color: Color(0xFF2E7D32)),
                              onPressed: () => _whatsapp(it, late ? 'late' : 'reminder'),
                            ),
                            IconButton(
                              tooltip: 'تسجيل سداد',
                              icon: const Icon(Icons.payments_outlined),
                              onPressed: () {
                                Navigator.pop(ctx);
                                _pay(it);
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final titles = ['العقارات', 'التقارير المالية'];
    return Scaffold(
      appBar: AppBar(
        title: Text(titles[_tab], style: const TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            tooltip: 'التنبيهات',
            onPressed: _showAlerts,
            icon: Badge(
              label: Text('${_alerts.length}'),
              isLabelVisible: _alerts.isNotEmpty,
              child: const Icon(Icons.notifications_outlined),
            ),
          ),
          IconButton(
            tooltip: 'الإعدادات',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween<Offset>(
                    begin: const Offset(0, 0.02), end: Offset.zero)
                .animate(anim),
            child: child,
          ),
        ),
        child: KeyedSubtree(
          key: ValueKey(_loading ? 'loading' : 'tab$_tab'),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : (_tab == 0 ? _propertiesTab() : _reportsTab()),
        ),
      ),
      floatingActionButton: AnimatedScale(
        scale: _tab == 0 ? 1 : 0,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutBack,
        child: FloatingActionButton.extended(
          onPressed: _tab == 0 ? () => _openForm() : null,
          icon: const Icon(Icons.add),
          label: const Text('إضافة عقار'),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.home_work_outlined),
              selectedIcon: Icon(Icons.home_work),
              label: 'العقارات'),
          NavigationDestination(
              icon: Icon(Icons.insights_outlined),
              selectedIcon: Icon(Icons.insights),
              label: 'التقارير'),
        ],
      ),
    );
  }

  // ---------------- العقارات ----------------
  Widget _propertiesTab() {
    final list = _filtered;
    final al = _alerts;
    final lateCount = al.where((i) => (daysUntilDue(i) ?? -1) < 0).length;
    final soonCount = al.length - lateCount;
    return Column(
      children: [
        if (al.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: _showAlerts,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFC62828).withAlpha(20),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.notifications_active, color: Color(0xFFC62828)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'تنبيهات: $lateCount متأخر • $soonCount قريب الاستحقاق',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const Icon(Icons.chevron_left),
                  ],
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            onChanged: (v) => setState(() => _query = v.trim()),
            decoration: const InputDecoration(
              hintText: 'ابحث بالعقار أو المستأجر أو الموقع',
              prefixIcon: Icon(Icons.search),
              contentPadding: EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: ChoiceChip(
                  label: const Text('الكل'),
                  selected: _filter == null,
                  onSelected: (_) => setState(() => _filter = null),
                ),
              ),
              for (final s in kStatuses)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: ChoiceChip(
                    label: Text(s),
                    selected: _filter == s,
                    onSelected: (_) => setState(() => _filter = s),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? _emptyState()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (_, i) => FadeSlideIn(
                      key: ValueKey(list[i]['id']),
                      index: i,
                      child: _propertyCard(list[i]),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _emptyState() {
    final has = _items.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(has ? Icons.search_off : Icons.apartment, size: 72, color: Colors.black26),
            const SizedBox(height: 12),
            Text(
              has ? 'لا توجد نتائج مطابقة' : 'لا توجد عقارات بعد\nاضغط "إضافة عقار" للبدء',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _propertyCard(Map<String, dynamic> item) {
    final color = statusColor(effStatus(item));
    final total = totalDue(item);
    final other = num0(item['other_amount']);
    final otherNote = (item['other_note'] ?? '').toString();
    final bal = num0(item['balance']);
    final atts = _atts[item['id'] as int];
    return AppCard(
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          leading: CircleAvatar(
            backgroundColor: color.withAlpha(30),
            child: Icon(Icons.apartment, color: color),
          ),
          title: Text('${item['name'] ?? ''}',
              style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                _statusChip(effStatus(item), color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('${item['tenant_name'] ?? ''}',
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
          trailing: Text(fmt(total),
              style: TextStyle(fontWeight: FontWeight.w800, color: color)),
          children: [
            _info(Icons.tag, 'كود العقار', '${item['id']}'),
            _info(Icons.location_on_outlined, 'الموقع', '${item['location'] ?? ''}'),
            if (item['lat'] != null && item['lng'] != null)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () => openInMaps(context,
                      (item['lat'] as num).toDouble(), (item['lng'] as num).toDouble()),
                  icon: const Icon(Icons.map_outlined, size: 18),
                  label: const Text('عرض على خريطة جوجل'),
                ),
              ),
            _info(Icons.place_outlined, 'العنوان', '${item['address'] ?? ''}'),
            _info(Icons.phone_outlined, 'الهاتف', '${item['tenant_phone'] ?? ''}'),
            _info(Icons.phone_forwarded_outlined, 'هاتف بديل', '${item['alt_phone'] ?? ''}'),
            _info(Icons.event_outlined, 'الاستحقاق', dueText(item)),
            _info(Icons.savings_outlined, 'التأمين', fmt(num0(item['deposit_amount']))),
            const Divider(height: 24),
            _info(Icons.payments_outlined, 'الإيجار', fmt(num0(item['rent_amount']))),
            _info(Icons.bolt_outlined, 'كهرباء', fmt(num0(item['electricity']))),
            _info(Icons.water_drop_outlined, 'مياه', fmt(num0(item['water']))),
            _info(Icons.local_fire_department_outlined, 'غاز', fmt(num0(item['gas']))),
            if (other > 0)
              _info(Icons.room_service_outlined,
                  otherNote.isEmpty ? 'خدمات أخرى' : 'خدمات ($otherNote)', fmt(other)),
            if (bal != 0)
              _info(Icons.account_balance_wallet_outlined,
                  bal > 0 ? 'رصيد سابق' : 'رصيد دائن', fmt(bal.abs())),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: color.withAlpha(20),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('إجمالي المستحق',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  Text(fmt(total),
                      style: TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 16, color: color)),
                ],
              ),
            ),
            if (atts != null) ...[
              _thumbs('صور البطاقة', atts['id'] ?? []),
              _thumbs('صور العقد', atts['contract'] ?? []),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _pay(item),
                icon: const Icon(Icons.payments),
                label: const Text('تسجيل سداد الإيجار'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: () => _openDetail(item),
                icon: const Icon(Icons.account_balance_outlined),
                label: const Text('الحساب والمدفوعات والمرافق'),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _waButton('تذكير', Icons.notifications_active,
                      const Color(0xFFF9A825), () => _whatsapp(item, 'reminder')),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _waButton('تأخير', Icons.warning_amber_rounded,
                      const Color(0xFFC62828), () => _whatsapp(item, 'late')),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _waButton('شكر', Icons.favorite, const Color(0xFF2E7D32),
                      () => _whatsapp(item, 'thanks')),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _openForm(item),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('تعديل'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _delete(item),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('حذف'),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(String? s, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
            color: c.withAlpha(30), borderRadius: BorderRadius.circular(8)),
        child: Text(s ?? '',
            style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w700)),
      );

  Widget _info(IconData icon, String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.black45),
          const SizedBox(width: 8),
          Text('$label: ', style: const TextStyle(color: Colors.black54)),
          Expanded(
            child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _waButton(String label, IconData icon, Color c, VoidCallback onTap) =>
      FilledButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: FilledButton.styleFrom(
          backgroundColor: c,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      );

  Widget _thumbs(String label, List<String> paths) {
    final ok = paths.where((e) => File(e).existsSync()).toList();
    if (ok.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label (${ok.length})', style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 6),
          SizedBox(
            height: 64,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: ok.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) => GestureDetector(
                onTap: () => showDialog(
                  context: context,
                  builder: (_) => Dialog(
                    child: InteractiveViewer(child: Image.file(File(ok[i]))),
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(File(ok[i]), width: 64, height: 64, fit: BoxFit.cover),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- التقارير المالية المجمعة ----------------
  Widget _reportsTab() {
    double rent = 0, utils = 0, deposit = 0, due = 0;
    var rented = 0, vacant = 0, late = 0;
    for (final i in _items) {
      rent += num0(i['rent_amount']);
      utils += utilitiesTotal(i);
      deposit += num0(i['deposit_amount']);
      final es = effStatus(i);
      if (es == 'متأخرات') {
        due += totalDue(i);
        late++;
      } else if (es == 'شاغر') {
        vacant++;
      } else {
        rented++;
      }
    }
    final key = intl.DateFormat('yyyy-MM').format(DateTime.now());
    double month = 0, allPaid = 0;
    for (final pm in _payments) {
      allPaid += num0(pm['amount']);
      if ((pm['paid_at'] ?? '').toString().startsWith(key)) month += num0(pm['amount']);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        FadeSlideIn(
          child: AppCard(
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: const LinearGradient(
                  colors: [Color(0xFF1B5E85), Color(0xFF2A8AB8)]),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('إجمالي الإيجارات الشهرية',
                    style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 6),
                Text(fmt(rent),
                    style: const TextStyle(
                        color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text('${_items.length} عقار  •  مؤجر $rented  •  شاغر $vacant  •  متأخرات $late',
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
        )),
        const SizedBox(height: 12),
        FadeSlideIn(index: 1, child: Row(children: [
          _stat('المرافق والخدمات', fmt(utils), Icons.bolt, const Color(0xFFEF6C00)),
          const SizedBox(width: 12),
          _stat('التأمينات', fmt(deposit), Icons.savings, const Color(0xFF00897B)),
        ])),
        const SizedBox(height: 12),
        FadeSlideIn(index: 2, child: Row(children: [
          _stat('متأخرات مستحقة', fmt(due), Icons.warning_amber_rounded,
              const Color(0xFFC62828)),
          const SizedBox(width: 12),
          _stat('عقارات شاغرة', '$vacant', Icons.key, const Color(0xFF6A1B9A)),
        ])),
        const SizedBox(height: 12),
        FadeSlideIn(index: 3, child: Row(children: [
          _stat('المحصّل هذا الشهر', fmt(month), Icons.account_balance_wallet,
              const Color(0xFF2E7D32)),
          const SizedBox(width: 12),
          _stat('إجمالي المحصّل', fmt(allPaid), Icons.savings_outlined,
              const Color(0xFF1B5E85)),
        ])),
        const SizedBox(height: 16),
        FadeSlideIn(index: 4, child: FilledButton.icon(
          onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) =>
                      ReportFilterScreen(props: _items, pays: _payments))),
          icon: const Icon(Icons.picture_as_pdf),
          label: const Text('التقرير الشامل (فلترة وتصدير PDF)'),
        )),
        const SizedBox(height: 24),
        const Text('سجل المدفوعات والإيصالات',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        if (_payments.isEmpty)
          const Text('لا توجد مدفوعات مسجلة بعد. سجّل سداداً من بطاقة العقار.',
              style: TextStyle(color: Colors.black54))
        else
          for (final pm in _payments.take(50))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AppCard(
                child: ListTile(
                  title: Text('${receiptNo(pm)} • ${pm['property_name']}',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(
                      '${pm['tenant_name']} • ${fmt(num0(pm['amount']))} • ${fmtDateStr(pm['paid_at'])}'),
                  trailing: IconButton.filledTonal(
                    onPressed: () => printReceipt(pm),
                    icon: const Icon(Icons.picture_as_pdf),
                    tooltip: 'طباعة الإيصال',
                  ),
                ),
              ),
            ),
      ],
    );
  }

  Widget _stat(String title, String value, IconData icon, Color c) => Expanded(
        child: AppCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                    radius: 18,
                    backgroundColor: c.withAlpha(30),
                    child: Icon(icon, color: c, size: 20)),
                const SizedBox(height: 10),
                Text(title, style: const TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(value,
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w800, color: c)),
                ),
              ],
            ),
          ),
        ),
      );
}
