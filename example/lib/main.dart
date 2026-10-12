import 'package:flutter/material.dart';

import 'auth_api.dart';

// Deliberately no widget Keys anywhere in this app.

void main() => runApp(DemoApp(api: FakeAuthApi()));

class DemoApp extends StatelessWidget {
  const DemoApp({super.key, required this.api});

  final AuthApi api;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Tester Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: LoginPage(api: api),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.api, this.message});

  final AuthApi api;
  final String? message;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit(BuildContext formContext) async {
    if (!Form.of(formContext).validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final token = await widget.api.login(_email.text.trim(), _password.text);
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
        builder: (_) => HomePage(api: widget.api, token: token),
      ));
    } on NetworkException {
      setState(() => _error = 'Network error. Check your connection.');
    } on InvalidCredentialsException {
      setState(() => _error = 'Wrong email or password.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Form(
          child: Builder(builder: (formContext) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.message != null) Text(widget.message!, style: const TextStyle(color: Colors.orange)),
              TextFormField(
                controller: _email,
                decoration: const InputDecoration(labelText: 'Email'),
                keyboardType: TextInputType.emailAddress,
                validator: (v) => (v == null || !v.contains('@')) ? 'Enter a valid email' : null,
              ),
              TextFormField(
                controller: _password,
                decoration: const InputDecoration(labelText: 'Password'),
                obscureText: true,
                validator: (v) => (v == null || v.length < 6) ? 'Password must be at least 6 characters' : null,
              ),
              const SizedBox(height: 24),
              if (_loading)
                const Center(child: CircularProgressIndicator()) // never settles
              else
                ElevatedButton(onPressed: () => _submit(formContext), child: const Text('Log in')),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: Colors.red)),
                TextButton(onPressed: () => _submit(formContext), child: const Text('Retry')),
              ],
            ],
          )),
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.api, required this.token});

  final AuthApi api;
  final String token;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<Product>? _products;
  int _cart = 0;
  bool _inStockOnly = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final products = await widget.api.products(widget.token);
      if (mounted) setState(() => _products = products);
    } on SessionExpiredException {
      if (!mounted) return;
      _logout(message: 'Session expired. Please sign in again.');
    }
  }

  void _logout({String? message}) {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => LoginPage(api: widget.api, message: message)),
      (_) => false,
    );
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text('You will need to sign in again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Log out')),
        ],
      ),
    );
    if (confirmed ?? false) _logout();
  }

  void _showFilters() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Filters'),
              SwitchListTile(
                title: const Text('Even products only'),
                value: _inStockOnly,
                onChanged: (v) => setSheetState(() => _inStockOnly = v),
              ),
              ElevatedButton(
                onPressed: () {
                  setState(() {});
                  Navigator.pop(context);
                },
                child: const Text('Apply'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final products = _products?.where((p) => !_inStockOnly || p.id.isEven).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text('Products · Cart: $_cart'),
        actions: [
          IconButton(tooltip: 'Filter', icon: const Icon(Icons.filter_list), onPressed: _showFilters),
          IconButton(tooltip: 'Log out', icon: const Icon(Icons.logout), onPressed: _confirmLogout),
        ],
      ),
      body: products == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                const Padding(padding: EdgeInsets.all(8), child: Text('Welcome back')),
                Expanded(
                  child: ListView.builder(
                    itemCount: products.length,
                    itemBuilder: (context, i) {
                      final p = products[i];
                      return ListTile(
                        title: Text(p.name),
                        subtitle: Text('\$${(p.priceCents / 100).toStringAsFixed(2)}'),
                        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => ProductPage(product: p, onAdd: () => setState(() => _cart++)),
                        )),
                        // Every row has an identical "Add" button.
                        trailing: ElevatedButton(onPressed: () => setState(() => _cart++), child: const Text('Add')),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class ProductPage extends StatelessWidget {
  const ProductPage({super.key, required this.product, required this.onAdd});

  final Product product;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(product.name)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${product.name} details'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                onAdd();
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${product.name} added')));
              },
              child: const Text('Add to cart'),
            ),
          ],
        ),
      ),
    );
  }
}
