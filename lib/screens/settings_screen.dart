import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../main.dart';
import '../providers/flux_provider.dart';
import '../services/equalizer_service.dart';
import 'auth_screen.dart';
import 'friends_screen.dart';
import 'equalizer_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _urlController;
  late TextEditingController _usernameController;
  late String _selectedQuality;
  late bool _isPublic;
  late bool _showTrending;

  @override
  void initState() {
    super.initState();
    final provider = Provider.of<FluxProvider>(context, listen: false);
    _urlController = TextEditingController(text: provider.baseUrl);
    _usernameController = TextEditingController(text: provider.username);
    _selectedQuality = provider.audioQuality;
    _isPublic = provider.isPublic;
    _showTrending = provider.showTrending;
  }

  @override
  void dispose() {
    _urlController.dispose();
    _usernameController.dispose();
    super.dispose();
  }

  void _saveSettings() {
    final provider = Provider.of<FluxProvider>(context, listen: false);
    provider.setBaseUrl(_urlController.text.trim());
    provider.setAudioQuality(_selectedQuality);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Configurações salvas!')),
    );
  }

  Future<void> _signOut() async {
    await Supabase.instance.client.auth.signOut();
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const AuthScreen()),
        (Route<dynamic> route) => false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser;
    final userEmail = user?.email ?? 'Usuário não logado';
    final isEmailVerified = user?.emailConfirmedAt != null;

    return Scaffold(
      backgroundColor: FluxApp.backgroundColor,
      appBar: AppBar(
        title: const Text('Configurações'),
        backgroundColor: FluxApp.surfaceColor,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // SEÇÃO: CONTA
          const Text(
            'CONTA',
            style: TextStyle(
              color: FluxApp.accentColor,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: FluxApp.cardColor,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: FluxApp.surfaceColor,
                    child: Icon(Icons.person, color: Colors.white),
                  ),
                  title: Row(
                    children: [
                      Flexible(
                        child: Text(
                          userEmail,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                      if (isEmailVerified) ...[
                        const SizedBox(width: 6),
                        const Tooltip(
                          message: 'E-mail verificado',
                          child: Icon(
                            Icons.verified,
                            color: FluxApp.accentColor,
                            size: 19,
                          ),
                        ),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    user == null
                        ? 'Sem sessão ativa'
                        : isEmailVerified
                            ? 'E-mail verificado • Plano Free'
                            : 'E-mail pendente de confirmação',
                    style: const TextStyle(
                      color: FluxApp.secondaryTextColor,
                    ),
                  ),
                ),
                const Divider(color: FluxApp.surfaceColor, height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: TextField(
                    controller: _usernameController,
                    decoration: InputDecoration(
                      labelText: 'Nome de Usuário',
                      labelStyle: const TextStyle(color: FluxApp.secondaryTextColor),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.05),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    style: const TextStyle(color: FluxApp.primaryTextColor),
                    onChanged: (val) {
                      final provider = Provider.of<FluxProvider>(context, listen: false);
                      provider.updateUsername(val.trim());
                    },
                  ),
                ),
                SwitchListTile(
                  title: const Text('Tornar minhas playlists públicas', style: TextStyle(color: Colors.white)),
                  value: _isPublic,
                  activeColor: FluxApp.accentColor,
                  onChanged: (val) {
                    setState(() => _isPublic = val);
                    Provider.of<FluxProvider>(context, listen: false).toggleIsPublic(val);
                  },
                ),
                const Divider(color: FluxApp.surfaceColor, height: 1),
                ListTile(
                  leading: const Icon(Icons.people_alt_outlined, color: Colors.white),
                  title: const Text('Amigos', style: TextStyle(color: Colors.white)),
                  trailing: const Icon(Icons.chevron_right, color: FluxApp.secondaryTextColor),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const FriendsScreen()),
                    );
                  },
                ),
                const Divider(color: FluxApp.surfaceColor, height: 1),
                ListTile(
                  leading: const Icon(Icons.logout, color: Colors.redAccent),
                  title: const Text('Sair da Conta', style: TextStyle(color: Colors.redAccent)),
                  onTap: _signOut,
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          // SEÇÃO: TÉCNICO
          const Text(
            'TÉCNICO / SERVIDOR',
            style: TextStyle(
              color: FluxApp.accentColor,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: FluxApp.cardColor,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Servidor Ngrok', style: TextStyle(color: FluxApp.secondaryTextColor, fontSize: 13)),
                const SizedBox(height: 8),
                TextField(
                  controller: _urlController,
                  decoration: InputDecoration(
                    hintText: 'https://xxx.ngrok.app',
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  style: const TextStyle(color: FluxApp.primaryTextColor),
                  onChanged: (_) => _saveSettings(), // Autosave
                ),
                const SizedBox(height: 20),
                const Text('Qualidade de Áudio', style: TextStyle(color: FluxApp.secondaryTextColor, fontSize: 13)),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: _selectedQuality,
                  dropdownColor: FluxApp.surfaceColor,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.05),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'low', child: Text('Baixa (Economia)')),
                    DropdownMenuItem(value: 'normal', child: Text('Normal (Padrão)')),
                    DropdownMenuItem(value: 'high', child: Text('Alta (Melhor áudio)')),
                    DropdownMenuItem(value: 'lossless', child: Text('Lossless (FLAC/OPUS)')),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => _selectedQuality = val);
                      _saveSettings(); // Autosave
                    }
                  },
                ),
                const SizedBox(height: 20),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Mostrar seção "Em Alta" na Home', style: TextStyle(color: Colors.white, fontSize: 15)),
                  value: _showTrending,
                  activeColor: FluxApp.accentColor,
                  onChanged: (val) {
                    setState(() => _showTrending = val);
                    Provider.of<FluxProvider>(context, listen: false).toggleShowTrending(val);
                  },
                ),
                const SizedBox(height: 12),
                // Equalizer shortcut
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.equalizer_rounded, color: FluxApp.accentColor),
                  title: const Text('Equalizer & Audio Effects', style: TextStyle(color: Colors.white, fontSize: 15)),
                  trailing: const Icon(Icons.chevron_right, color: FluxApp.secondaryTextColor),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const EqualizerScreen()),
                    );
                  },
                ),

              ],
            ),
          ),
        ],
      ),
    );
  }
}
