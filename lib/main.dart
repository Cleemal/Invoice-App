import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------- helpers ----------
double parse(String s) => double.tryParse(s.replaceAll(',', '').trim()) ?? 0;
String trimNum(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();
String money(double v, [String cur = '']) {
  final p = v.toStringAsFixed(2).split('.');
  final whole = p[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  return cur.isEmpty ? '$whole.${p[1]}' : '$cur $whole.${p[1]}';
}
String two(int n) => n.toString().padLeft(2, '0');
String fmtDate(DateTime d) => '${two(d.day)}/${two(d.month)}/${d.year}';
Color statusColor(String s) {
  switch (s) {
    case 'paid':
      return Colors.green;
    case 'sent':
      return Colors.blue;
    case 'overdue':
      return Colors.red;
    default:
      return Colors.grey;
  }
}

// ---------- data ----------
class Business {
  String name, address, phone, email, payment, currency;
  Business({this.name = '', this.address = '', this.phone = '', this.email = '', this.payment = '', this.currency = 'MWK'});
  Map<String, dynamic> toJson() => {'name': name, 'address': address, 'phone': phone, 'email': email, 'payment': payment, 'currency': currency};
  factory Business.fromJson(Map<String, dynamic> j) => Business(
      name: j['name'] ?? '', address: j['address'] ?? '', phone: j['phone'] ?? '',
      email: j['email'] ?? '', payment: j['payment'] ?? '', currency: j['currency'] ?? 'MWK');
}

class Client {
  String id, name, phone, email, address;
  Client({required this.id, required this.name, this.phone = '', this.email = '', this.address = ''});
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'phone': phone, 'email': email, 'address': address};
  factory Client.fromJson(Map<String, dynamic> j) => Client(
      id: j['id'] ?? '', name: j['name'] ?? '', phone: j['phone'] ?? '', email: j['email'] ?? '', address: j['address'] ?? '');
}

class Item {
  String desc;
  double qty, price;
  Item({required this.desc, this.qty = 1, this.price = 0});
  Map<String, dynamic> toJson() => {'desc': desc, 'qty': qty, 'price': price};
  factory Item.fromJson(Map<String, dynamic> j) =>
      Item(desc: j['desc'] ?? '', qty: (j['qty'] ?? 1).toDouble(), price: (j['price'] ?? 0).toDouble());
}

class Invoice {
  String id, clientId, status, notes;
  int number;
  List<Item> items;
  double taxPct, discount;
  DateTime date, due;
  Invoice({required this.id, required this.number, this.clientId = '', List<Item>? items, this.taxPct = 0,
      this.discount = 0, DateTime? date, DateTime? due, this.status = 'draft', this.notes = ''})
      : items = items ?? [],
        date = date ?? DateTime.now(),
        due = due ?? DateTime.now().add(const Duration(days: 14));

  String get code => 'INV-${number.toString().padLeft(4, '0')}';
  double get subtotal => items.fold(0.0, (s, i) => s + i.qty * i.price);
  double get tax => (subtotal - discount) * taxPct / 100;
  double get total => subtotal - discount + tax;
  String get shownStatus {
    final n = DateTime.now();
    if (status == 'sent' && due.isBefore(DateTime(n.year, n.month, n.day))) return 'overdue';
    return status;
  }

  Map<String, dynamic> toJson() => {
        'id': id, 'number': number, 'clientId': clientId, 'items': items.map((e) => e.toJson()).toList(),
        'taxPct': taxPct, 'discount': discount, 'date': date.toIso8601String(), 'due': due.toIso8601String(),
        'status': status, 'notes': notes,
      };
  factory Invoice.fromJson(Map<String, dynamic> j) => Invoice(
        id: j['id'] ?? '', number: j['number'] ?? 1, clientId: j['clientId'] ?? '',
        items: ((j['items'] ?? []) as List).map((e) => Item.fromJson(e as Map<String, dynamic>)).toList(),
        taxPct: (j['taxPct'] ?? 0).toDouble(), discount: (j['discount'] ?? 0).toDouble(),
        date: DateTime.parse(j['date']), due: DateTime.parse(j['due']),
        status: j['status'] ?? 'draft', notes: j['notes'] ?? '',
      );
}

class Store extends ChangeNotifier {
  Business business = Business();
  List<Client> clients = [];
  List<Invoice> invoices = [];

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final b = p.getString('business');
    if (b != null) business = Business.fromJson(jsonDecode(b) as Map<String, dynamic>);
    clients = (jsonDecode(p.getString('clients') ?? '[]') as List)
        .map((e) => Client.fromJson(e as Map<String, dynamic>)).toList();
    invoices = (jsonDecode(p.getString('invoices') ?? '[]') as List)
        .map((e) => Invoice.fromJson(e as Map<String, dynamic>)).toList();
    notifyListeners();
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('business', jsonEncode(business.toJson()));
    await p.setString('clients', jsonEncode(clients.map((e) => e.toJson()).toList()));
    await p.setString('invoices', jsonEncode(invoices.map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  int get nextNumber => invoices.isEmpty ? 1 : invoices.map((i) => i.number).reduce((a, b) => a > b ? a : b) + 1;
  Client? clientById(String id) {
    for (final c in clients) {
      if (c.id == id) return c;
    }
    return null;
  }
}

final store = Store();

// ---------- app ----------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await store.load();
  runApp(const InvoiceApp());
}

class InvoiceApp extends StatelessWidget {
  const InvoiceApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Invoice Maker',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF1B5E20), useMaterial3: true),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int tab = 0;
  @override
  Widget build(BuildContext context) {
    const pages = [InvoicesTab(), ClientsTab(), BusinessTab()];
    return Scaffold(
      body: pages[tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.receipt_long), label: 'Invoices'),
          NavigationDestination(icon: Icon(Icons.people), label: 'Clients'),
          NavigationDestination(icon: Icon(Icons.store), label: 'Business'),
        ],
      ),
    );
  }
}

// ---------- invoices tab (dashboard + list) ----------
class InvoicesTab extends StatelessWidget {
  const InvoicesTab({super.key});

  Widget stat(String label, double v, String cur, Color color) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(money(v, cur), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final cur = store.business.currency;
        double sum(bool Function(Invoice) f) => store.invoices.where(f).fold(0.0, (s, i) => s + i.total);
        final list = [...store.invoices]..sort((a, b) => b.number.compareTo(a.number));
        return Scaffold(
          appBar: AppBar(title: const Text('Invoices')),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const InvoiceEditor())),
            icon: const Icon(Icons.add),
            label: const Text('New invoice'),
          ),
          body: ListView(padding: const EdgeInsets.all(12), children: [
            Row(children: [
              stat('Paid', sum((i) => i.shownStatus == 'paid'), cur, Colors.green),
              stat('Unpaid', sum((i) => i.shownStatus == 'sent'), cur, Colors.blue),
            ]),
            Row(children: [
              stat('Overdue', sum((i) => i.shownStatus == 'overdue'), cur, Colors.red),
              stat('Drafts', sum((i) => i.shownStatus == 'draft'), cur, Colors.grey),
            ]),
            const SizedBox(height: 8),
            if (list.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('No invoices yet.\nTap "New invoice" to make your first one.', textAlign: TextAlign.center)),
              ),
            ...list.map((i) => Card(
                  child: ListTile(
                    title: Text('${i.code}  •  ${store.clientById(i.clientId)?.name ?? 'No client'}'),
                    subtitle: Text('Due ${fmtDate(i.due)}'),
                    trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(money(i.total, cur), style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text(i.shownStatus.toUpperCase(),
                          style: TextStyle(color: statusColor(i.shownStatus), fontSize: 11, fontWeight: FontWeight.bold)),
                    ]),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => InvoiceEditor(existing: i))),
                  ),
                )),
            const SizedBox(height: 80),
          ]),
        );
      },
    );
  }
}

// ---------- clients tab ----------
Future<Client?> clientDialog(BuildContext context, [Client? c]) {
  final name = TextEditingController(text: c?.name);
  final phone = TextEditingController(text: c?.phone);
  final email = TextEditingController(text: c?.email);
  final addr = TextEditingController(text: c?.address);
  return showDialog<Client>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(c == null ? 'New client' : 'Edit client'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
          TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone')),
          TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email')),
          TextField(controller: addr, decoration: const InputDecoration(labelText: 'Address')),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (name.text.trim().isEmpty) return;
            Navigator.pop(ctx, Client(
              id: c?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
              name: name.text.trim(), phone: phone.text.trim(), email: email.text.trim(), address: addr.text.trim()));
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

class ClientsTab extends StatelessWidget {
  const ClientsTab({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Clients')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () async {
            final c = await clientDialog(context);
            if (c != null) {
              store.clients.add(c);
              await store.save();
            }
          },
          icon: const Icon(Icons.person_add),
          label: const Text('New client'),
        ),
        body: store.clients.isEmpty
            ? const Center(child: Text('No clients yet.'))
            : ListView(children: store.clients.map((c) => ListTile(
                  leading: CircleAvatar(child: Text(c.name[0].toUpperCase())),
                  title: Text(c.name),
                  subtitle: Text([c.phone, c.email].where((s) => s.isNotEmpty).join('  •  ')),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      store.clients.removeWhere((x) => x.id == c.id);
                      await store.save();
                    },
                  ),
                  onTap: () async {
                    final r = await clientDialog(context, c);
                    if (r != null) {
                      final idx = store.clients.indexWhere((x) => x.id == c.id);
                      store.clients[idx] = r;
                      await store.save();
                    }
                  },
                )).toList()),
      ),
    );
  }
}

// ---------- business tab ----------
class BusinessTab extends StatefulWidget {
  const BusinessTab({super.key});
  @override
  State<BusinessTab> createState() => _BusinessTabState();
}

class _BusinessTabState extends State<BusinessTab> {
  late TextEditingController name, address, phone, email, payment, currency;
  @override
  void initState() {
    super.initState();
    final b = store.business;
    name = TextEditingController(text: b.name);
    address = TextEditingController(text: b.address);
    phone = TextEditingController(text: b.phone);
    email = TextEditingController(text: b.email);
    payment = TextEditingController(text: b.payment);
    currency = TextEditingController(text: b.currency);
  }

  Widget field(TextEditingController c, String label, {int lines = 1, TextInputType? type}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(controller: c, maxLines: lines, keyboardType: type,
            decoration: InputDecoration(labelText: label, border: const OutlineInputBorder())),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My business')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        field(name, 'Business name'),
        field(address, 'Address', lines: 2),
        field(phone, 'Phone', type: TextInputType.phone),
        field(email, 'Email', type: TextInputType.emailAddress),
        field(currency, 'Currency (e.g. MWK, USD)'),
        field(payment, 'Payment details (bank, Airtel Money, TNM Mpamba...)', lines: 3),
        FilledButton(
          onPressed: () async {
            final b = store.business;
            b.name = name.text.trim();
            b.address = address.text.trim();
            b.phone = phone.text.trim();
            b.email = email.text.trim();
            b.payment = payment.text.trim();
            b.currency = currency.text.trim().isEmpty ? 'MWK' : currency.text.trim().toUpperCase();
            await store.save();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
            }
          },
          child: const Text('Save'),
        ),
      ]),
    );
  }
}

// ---------- item dialog ----------
Future<Item?> itemDialog(BuildContext context, [Item? it]) {
  final desc = TextEditingController(text: it?.desc);
  final qty = TextEditingController(text: it == null ? '1' : trimNum(it.qty));
  final price = TextEditingController(text: it == null ? '' : trimNum(it.price));
  return showDialog<Item>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(it == null ? 'Add item' : 'Edit item'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: desc, decoration: const InputDecoration(labelText: 'Description')),
          TextField(controller: qty, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Quantity')),
          TextField(controller: price, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Unit price')),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            if (desc.text.trim().isEmpty) return;
            Navigator.pop(ctx, Item(desc: desc.text.trim(), qty: parse(qty.text), price: parse(price.text)));
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

// ---------- invoice editor ----------
class InvoiceEditor extends StatefulWidget {
  final Invoice? existing;
  const InvoiceEditor({super.key, this.existing});
  @override
  State<InvoiceEditor> createState() => _InvoiceEditorState();
}

class _InvoiceEditorState extends State<InvoiceEditor> {
  late Invoice inv;
  late TextEditingController tax, disc, notes;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    inv = e == null
        ? Invoice(id: DateTime.now().microsecondsSinceEpoch.toString(), number: store.nextNumber)
        : Invoice.fromJson(e.toJson());
    tax = TextEditingController(text: inv.taxPct == 0 ? '' : trimNum(inv.taxPct));
    disc = TextEditingController(text: inv.discount == 0 ? '' : trimNum(inv.discount));
    notes = TextEditingController(text: inv.notes);
  }

  void snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> pick(bool isDue) async {
    final d = await showDatePicker(
      context: context,
      initialDate: isDue ? inv.due : inv.date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() {
        if (isDue) {
          inv.due = d;
        } else {
          inv.date = d;
        }
      });
    }
  }

  Future<void> save() async {
    if (inv.clientId.isEmpty) return snack('Please choose a client');
    if (inv.items.isEmpty) return snack('Please add at least one item');
    inv.notes = notes.text.trim();
    final i = store.invoices.indexWhere((x) => x.id == inv.id);
    if (i >= 0) {
      store.invoices[i] = inv;
    } else {
      store.invoices.add(inv);
    }
    await store.save();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final cur = store.business.currency;
    return Scaffold(
      appBar: AppBar(
        title: Text(inv.code),
        actions: [
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            tooltip: 'Share PDF',
            onPressed: () {
              if (inv.clientId.isEmpty || inv.items.isEmpty) return snack('Choose a client and add an item first');
              inv.notes = notes.text.trim();
              sharePdf(inv);
            },
          ),
          if (widget.existing != null)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                store.invoices.removeWhere((x) => x.id == inv.id);
                await store.save();
                if (mounted) Navigator.pop(context);
              },
            ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        DropdownButtonFormField<String>(
          value: store.clientById(inv.clientId) == null ? null : inv.clientId,
          decoration: const InputDecoration(labelText: 'Client', border: OutlineInputBorder()),
          items: store.clients.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))).toList(),
          onChanged: (v) => setState(() => inv.clientId = v ?? ''),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.person_add),
            label: const Text('New client'),
            onPressed: () async {
              final c = await clientDialog(context);
              if (c != null) {
                store.clients.add(c);
                await store.save();
                setState(() => inv.clientId = c.id);
              }
            },
          ),
        ),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: () => pick(false), child: Text('Date: ${fmtDate(inv.date)}'))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton(onPressed: () => pick(true), child: Text('Due: ${fmtDate(inv.due)}'))),
        ]),
        const SizedBox(height: 16),
        const Text('Items', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        ...inv.items.asMap().entries.map((e) => ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(e.value.desc),
              subtitle: Text('${trimNum(e.value.qty)} × ${money(e.value.price)}'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(money(e.value.qty * e.value.price)),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() => inv.items.removeAt(e.key)),
                ),
              ]),
              onTap: () async {
                final r = await itemDialog(context, e.value);
                if (r != null) setState(() => inv.items[e.key] = r);
              },
            )),
        TextButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('Add item'),
          onPressed: () async {
            final r = await itemDialog(context);
            if (r != null) setState(() => inv.items.add(r));
          },
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: TextField(
              controller: disc,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: 'Discount ($cur)', border: const OutlineInputBorder()),
              onChanged: (v) => setState(() => inv.discount = parse(v)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: tax,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Tax (%)', border: OutlineInputBorder()),
              onChanged: (v) => setState(() => inv.taxPct = parse(v)),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              _row('Subtotal', money(inv.subtotal, cur)),
              if (inv.discount > 0) _row('Discount', '- ${money(inv.discount, cur)}'),
              if (inv.taxPct > 0) _row('Tax (${trimNum(inv.taxPct)}%)', money(inv.tax, cur)),
              const Divider(),
              _row('TOTAL', money(inv.total, cur), bold: true),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: inv.status == 'overdue' ? 'sent' : inv.status,
          decoration: const InputDecoration(labelText: 'Status', border: OutlineInputBorder()),
          items: const [
            DropdownMenuItem(value: 'draft', child: Text('Draft')),
            DropdownMenuItem(value: 'sent', child: Text('Sent')),
            DropdownMenuItem(value: 'paid', child: Text('Paid')),
          ],
          onChanged: (v) => setState(() => inv.status = v ?? 'draft'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: notes,
          maxLines: 2,
          decoration: const InputDecoration(labelText: 'Notes (optional)', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: save, child: const Padding(padding: EdgeInsets.all(12), child: Text('Save invoice'))),
        const SizedBox(height: 24),
      ]),
    );
  }

  Widget _row(String a, String b, {bool bold = false}) {
    final s = TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal, fontSize: bold ? 16 : 14);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(a, style: s), Text(b, style: s)]),
    );
  }
}

// ---------- PDF ----------
Future<void> sharePdf(Invoice inv) async {
  final b = store.business;
  final c = store.clientById(inv.clientId);
  final cur = b.currency;
  final doc = pw.Document();

  pw.TextStyle ts(bool bold, [double size = 11]) =>
      pw.TextStyle(fontSize: size, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal);
  pw.Widget cell(String t, {bool bold = false}) =>
      pw.Padding(padding: const pw.EdgeInsets.all(6), child: pw.Text(t, style: ts(bold)));
  pw.Widget line(String a, String v, {bool bold = false}) => pw.Container(
        width: 230,
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [pw.Text(a, style: ts(bold, bold ? 13 : 11)), pw.Text(v, style: ts(bold, bold ? 13 : 11))]),
      );

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    build: (ctx) => [
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text(b.name.isEmpty ? 'My Business' : b.name, style: ts(true, 20)),
          if (b.address.isNotEmpty) pw.Text(b.address),
          if (b.phone.isNotEmpty) pw.Text(b.phone),
          if (b.email.isNotEmpty) pw.Text(b.email),
        ]),
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.Text('INVOICE', style: ts(true, 22)),
          pw.Text(inv.code),
          pw.Text('Date: ${fmtDate(inv.date)}'),
          pw.Text('Due: ${fmtDate(inv.due)}'),
        ]),
      ]),
      pw.SizedBox(height: 24),
      pw.Text('Bill to', style: ts(true)),
      pw.Text(c?.name ?? ''),
      if (c != null && c.address.isNotEmpty) pw.Text(c.address),
      if (c != null && c.phone.isNotEmpty) pw.Text(c.phone),
      if (c != null && c.email.isNotEmpty) pw.Text(c.email),
      pw.SizedBox(height: 16),
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey400),
        columnWidths: {
          0: const pw.FlexColumnWidth(4),
          1: const pw.FlexColumnWidth(1),
          2: const pw.FlexColumnWidth(2),
          3: const pw.FlexColumnWidth(2),
        },
        children: [
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: PdfColors.grey300),
            children: [cell('Description', bold: true), cell('Qty', bold: true), cell('Price', bold: true), cell('Amount', bold: true)],
          ),
          ...inv.items.map((i) => pw.TableRow(children: [
                cell(i.desc), cell(trimNum(i.qty)), cell(money(i.price)), cell(money(i.qty * i.price)),
              ])),
        ],
      ),
      pw.SizedBox(height: 12),
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.end, children: [
        pw.Column(children: [
          line('Subtotal', money(inv.subtotal, cur)),
          if (inv.discount > 0) line('Discount', '- ${money(inv.discount, cur)}'),
          if (inv.taxPct > 0) line('Tax (${trimNum(inv.taxPct)}%)', money(inv.tax, cur)),
          pw.Divider(),
          line('TOTAL', money(inv.total, cur), bold: true),
        ]),
      ]),
      pw.SizedBox(height: 24),
      if (b.payment.isNotEmpty) ...[pw.Text('Payment details', style: ts(true)), pw.Text(b.payment), pw.SizedBox(height: 12)],
      if (inv.notes.isNotEmpty) ...[pw.Text('Notes', style: ts(true)), pw.Text(inv.notes)],
    ],
  ));

  await Printing.sharePdf(bytes: await doc.save(), filename: '${inv.code}.pdf');
}