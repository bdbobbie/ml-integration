# GitHub Upload Authentication Fix

## 🔧 Issue Diagnosis

The GitHub upload is failing with "Bad credentials" error. This indicates the GitHub token lacks proper permissions or is incorrectly configured.

## 🛠️ Step-by-Step Solution

### 1. Create New Personal Access Token

**Go to GitHub Settings:**
1. Visit https://github.com/settings/tokens
2. Click "Generate new token (classic)" or "Generate new token"
3. Set token name: "ML Integration Release v1.0.0"
4. Set expiration: 90 days
5. Select scopes:
   - ✅ `repo` (Full control of private repositories)
   - ✅ `workflow` (Update GitHub Action workflows)
   - ✅ `write:packages` (Write packages)
   - ✅ `read:packages` (Read packages)

### 2. Configure Git with New Token

```bash
# Remove old token
git config --global --unset github.token

# Set new token (replace YOUR_NEW_TOKEN_HERE)
git config --global github.token YOUR_NEW_TOKEN_HERE

# Verify token is set
git config --global --get github.token
```

### 3. Upload Release Assets

```bash
# Upload the app bundle
curl -X POST \
  -H "Authorization: token YOUR_NEW_TOKEN_HERE" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @"ML Integration.app" \
  https://api.github.com/repos/bdbobbie/ml-integration/releases/tags/v1.0.0/assets

# Upload the zip file
curl -X POST \
  -H "Authorization: token YOUR_NEW_TOKEN_HERE" \
  -H "Content-Type: application/zip" \
  --data-binary @"ML_Integration_Production_v1.0.0.zip" \
  https://api.github.com/repos/bdbobbie/ml-integration/releases/tags/v1.0.0/assets
```

### 4. Alternative: Use GitHub CLI

```bash
# Install GitHub CLI
brew install gh

# Login
gh auth login

# Upload release assets
gh release upload v1.0.0 ML_Integration_Production_v1.0.0.zip
```

## 🔍 Verification Steps

1. **Test Token**: Verify new token works with API call
2. **Upload Assets**: Upload both .app and .zip files
3. **Check Release**: Verify assets appear on GitHub release page
4. **Test Download**: Confirm download links work properly

## 🚨 Common Issues & Solutions

### Issue: "Bad credentials"
- **Cause**: Token lacks `repo` scope or is expired
- **Solution**: Create new token with proper scopes

### Issue: "Not Found" 
- **Cause**: Release tag doesn't exist
- **Solution**: Ensure v1.0.0 tag is pushed first

### Issue: Asset upload fails
- **Cause**: File too large or wrong content type
- **Solution**: Use zip file for larger bundles

## 📋 Quick Fix Commands

```bash
# 1. Create new token at: https://github.com/settings/tokens
# 2. Configure git:
git config --global github.token YOUR_NEW_TOKEN

# 3. Upload assets:
curl -X POST -H "Authorization: token YOUR_NEW_TOKEN_HERE" \
  -H "Content-Type: application/zip" \
  --data-binary @"ML_Integration_Production_v1.0.0.zip" \
  https://api.github.com/repos/bdbobbie/ml-integration/releases/tags/v1.0.0/assets
```

## 🎯 Success Criteria

- ✅ Token created with proper scopes
- ✅ Git configured with new token
- ✅ Assets uploaded successfully
- ✅ Release page shows downloadable files
- ✅ Users can download and install app

---

**Next Action**: Follow the steps above to resolve authentication and complete release deployment.
