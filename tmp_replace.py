import os

filepath = r'c:\Users\Aryan\Documents\Projects\oxplayer-wrapper\oxplayer-android\lib\features\welcome\welcome_screen.dart'
with open(filepath, 'r', encoding='utf-8') as f:
    lines = f.readlines()

new_lines = lines[:407]

new_code = """
  bool get _showQr {
    final link = _qrData;
    return !kIsWeb && _cloudPasswordStep == null && _smsChallenge == null && link != null && link.isNotEmpty;
  }
  
  bool get _showCodeStep => !kIsWeb && _cloudPasswordStep == null && _smsChallenge != null;
  
  bool get _showPhoneStep => !kIsWeb && _cloudPasswordStep == null && _smsChallenge == null && !_showQr && _configError == null && _authWaitPhoneNumber && _loginPath == _WelcomeLoginPath.phone;
  
  bool get _showMethodChoice => !kIsWeb && _cloudPasswordStep == null && _smsChallenge == null && !_showQr && _configError == null && _authWaitPhoneNumber && _loginPath == _WelcomeLoginPath.unset;
  
  bool get _showAuthProgress => !kIsWeb && _configError == null && _cloudPasswordStep == null && !_showQr && !_showCodeStep && !_showPhoneStep && !_showMethodChoice;

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Scaffold(
        backgroundColor: const Color(0xFF0B0F19),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final isDesktop = constraints.maxWidth >= 1024;
            
            return CustomScrollView(
              slivers: [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1100),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: isDesktop ? 40 : 24,
                          vertical: isDesktop ? 60 : 32,
                        ),
                        child: isDesktop
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(child: _buildHeroLeft()),
                                  const SizedBox(width: 80),
                                  Expanded(child: _buildAuthCard()),
                                ],
                              )
                            : Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _buildHeroLeft(),
                                  const SizedBox(height: 40),
                                  _buildAuthCard(),
                                ],
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeroLeft() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Image.asset(
          'assets/icon.png',
          width: 64,
          height: 64,
          filterQuality: FilterQuality.high,
        ),
        const SizedBox(height: 24),
        const Text(
          'OXPlayer',
          style: TextStyle(
            color: Color(0xFFE5E7EB),
            fontSize: 36,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Sign in with Telegram to continue.\\nAccess your full cloud media library.',
          style: TextStyle(
            color: Color(0xFF9CA3AF),
            fontSize: 16,
            height: 1.5,
          ),
        ),
      ],
    );
  }

  Widget _buildAuthCard() {
    return Card(
      color: const Color(0xFF111827),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFF1F2937)),
      ),
      elevation: 12,
      shadowColor: Colors.black45,
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_configError != null)
              Text(
                _configError!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 15, height: 1.4),
                textAlign: TextAlign.center,
              )
            else if (_showAuthProgress)
              _buildProgressPanel()
            else if (_cloudPasswordStep != null)
              _buildPasswordPanel()
            else if (_showCodeStep)
              _buildCodePanel()
            else ...[
              if (_loginPath == _WelcomeLoginPath.unset || _loginPath == _WelcomeLoginPath.qr || _loginPath == _WelcomeLoginPath.phone)
                 _buildMethodSelector(),
              const SizedBox(height: 24),
              if (_showQr)
                _buildQrPanel()
              else if (_showPhoneStep)
                _buildPhonePanel()
              else if (_showMethodChoice)
                const SizedBox(height: 100, child: Center(child: Text('Select a sign-in method.', style: TextStyle(color: Color(0xFF9CA3AF))))),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMethodSelector() {
    final isQr = _loginPath == _WelcomeLoginPath.unset ? true : _loginPath == _WelcomeLoginPath.qr;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0B0F19),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1F2937)),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: const BorderRadius.horizontal(left: Radius.circular(11)),
              onTap: _onPickQrLogin,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: isQr ? const Color(0xFF1F2937) : Colors.transparent,
                  borderRadius: const BorderRadius.horizontal(left: Radius.circular(11)),
                ),
                child: Center(
                  child: Text(
                    'QR code',
                    style: TextStyle(
                      color: isQr ? const Color(0xFFE5E7EB) : const Color(0xFF9CA3AF),
                      fontWeight: isQr ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: InkWell(
              borderRadius: const BorderRadius.horizontal(right: Radius.circular(11)),
              onTap: _onPickPhoneLogin,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: !isQr ? const Color(0xFF1F2937) : Colors.transparent,
                  borderRadius: const BorderRadius.horizontal(right: Radius.circular(11)),
                ),
                child: Center(
                  child: Text(
                    'Phone',
                    style: TextStyle(
                      color: !isQr ? const Color(0xFFE5E7EB) : const Color(0xFF9CA3AF),
                      fontWeight: !isQr ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQrPanel() {
    final link = _qrData ?? '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeFocus(
          child: Container(
             padding: const EdgeInsets.all(16),
             decoration: BoxDecoration(
               color: Colors.white,
               borderRadius: BorderRadius.circular(12),
             ),
             child: QrImageView(
               data: link,
               size: 240,
               backgroundColor: Colors.white,
               errorCorrectionLevel: QrErrorCorrectLevel.M,
               gapless: true,
               errorStateBuilder: (context, err) {
                 return const Padding(
                   padding: EdgeInsets.all(16),
                   child: Text(
                     'QR render error',
                     style: TextStyle(color: Colors.red, fontSize: 12),
                     textAlign: TextAlign.center,
                   ),
                 );
               },
             ),
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Waiting for scan...',
          style: TextStyle(color: Color(0xFFE5E7EB), fontWeight: FontWeight.w600, fontSize: 16),
        ),
        const SizedBox(height: 8),
        const Text(
          'Open Telegram → Settings → Devices → Scan QR',
          style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 14),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        FocusTraversalOrder(
          order: const NumericFocusOrder(0),
          child: OxplayerButton(
            onPressed: _tdlibBusy ? null : _onBackFromQrStep,
            child: _tdlibBusy
                ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Back'),
          ),
        ),
      ],
    );
  }

  Widget _buildPhonePanel() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Enter Phone Number',
          style: TextStyle(color: Color(0xFFE5E7EB), fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Text(
          'Include country code (e.g. +1...)',
          style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 14),
        ),
        const SizedBox(height: 16),
        FocusTraversalOrder(
          order: const NumericFocusOrder(0),
          child: Theme(
            data: ThemeData.dark(),
            child: TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF0B0F19),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF1F2937))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF7C3AED), width: 2)),
                hintText: '+1 234 567 8900',
                hintStyle: const TextStyle(color: Colors.white30),
              ),
              onSubmitted: (_) => _onSubmitPhoneNumber(),
            ),
          ),
        ),
        const SizedBox(height: 24),
        FocusTraversalOrder(
          order: const NumericFocusOrder(1),
          child: OxplayerButton(
            onPressed: _phoneSubmitting || _tdlibBusy ? null : _onSubmitPhoneNumber,
            child: _phoneSubmitting
                ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Send Code'),
          ),
        ),
        const SizedBox(height: 16),
        FocusTraversalOrder(
          order: const NumericFocusOrder(2),
          child: TextButton(
            onPressed: (_phoneSubmitting || _tdlibBusy) ? null : _onBackFromPhoneStep,
            child: const Text('Back', style: TextStyle(color: Color(0xFF9CA3AF))),
          ),
        ),
      ],
    );
  }

  Widget _buildCodePanel() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Enter Code',
          style: TextStyle(color: Color(0xFFE5E7EB), fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Text(
          _loginCodeInstruction(_smsChallenge),
          style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 15, height: 1.4),
        ),
        const SizedBox(height: 24),
        FocusTraversalOrder(
          order: const NumericFocusOrder(0),
          child: Theme(
            data: ThemeData.dark(),
            child: TextField(
              controller: _loginCodeController,
              keyboardType: TextInputType.number,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 20, letterSpacing: 4),
              textAlign: TextAlign.center,
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF0B0F19),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF1F2937))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF7C3AED), width: 2)),
              ),
              onSubmitted: (_) => _onSubmitLoginCode(),
            ),
          ),
        ),
        const SizedBox(height: 24),
        FocusTraversalOrder(
          order: const NumericFocusOrder(1),
          child: OxplayerButton(
            onPressed: _codeSubmitting || _tdlibBusy ? null : _onSubmitLoginCode,
            child: _codeSubmitting
                ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Verify'),
          ),
        ),
        const SizedBox(height: 16),
        FocusTraversalOrder(
          order: const NumericFocusOrder(2),
          child: TextButton(
            onPressed: (_codeSubmitting || _tdlibBusy) ? null : _onBackFromCodeStep,
            child: const Text('Back to Phone', style: TextStyle(color: Color(0xFF9CA3AF))),
          ),
        ),
      ],
    );
  }

  Widget _buildPasswordPanel() {
    final hint = _cloudPasswordStep?.hint ?? '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Two-Step Verification',
          style: TextStyle(color: Color(0xFFE5E7EB), fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        const Text(
          'This account is protected with an additional password.',
          style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 15),
        ),
        if (hint.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF1F2937).withOpacity(0.5),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF374151)),
            ),
            child: Row(
              children: [
                const Icon(Icons.lightbulb_outline, color: Color(0xFFFBBF24), size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Hint: $hint',
                    style: const TextStyle(color: Color(0xFFD1D5DB), fontStyle: FontStyle.italic),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        FocusTraversalOrder(
          order: const NumericFocusOrder(0),
          child: Theme(
            data: ThemeData.dark(),
            child: TextField(
              controller: _passwordController,
              obscureText: true,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF0B0F19),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF1F2937))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF7C3AED), width: 2)),
                labelText: 'Password',
                labelStyle: const TextStyle(color: Color(0xFF9CA3AF)),
              ),
              onSubmitted: (_) => _onSubmitCloudPassword(),
            ),
          ),
        ),
        const SizedBox(height: 24),
        FocusTraversalOrder(
          order: const NumericFocusOrder(1),
          child: OxplayerButton(
            onPressed: _passwordSubmitting || _tdlibBusy ? null : _onSubmitCloudPassword,
            child: _passwordSubmitting
                ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Continue'),
          ),
        ),
      ],
    );
  }

  Widget _buildProgressPanel() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(height: 48),
        const CircularProgressIndicator(color: Color(0xFF7C3AED)),
        const SizedBox(height: 24),
        Text(
          (_tdlibBusy || _serverAuthBusy) ? 'Connecting to Telegram...' : 'Starting up...',
          style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 16),
        ),
        const SizedBox(height: 48),
      ],
    );
  }
}
"""

new_lines.append(new_code)

with open(filepath, 'w', encoding='utf-8') as f:
    f.writelines(new_lines)
print('Done!')
