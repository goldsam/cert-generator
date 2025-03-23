using System;
using System.IO;
using System.Threading.Tasks;
using Xunit;

// Make sure to include the appropriate namespaces for your module:
using CertGenerator;
using CertGenerator.Testcontainers; // Replace with the actual namespace of your CertGeneratorBuilder & container classes

namespace CertGeneratorModuleTests
{
    public class CertGeneratorContainerTests : IAsyncLifetime
    {
        private readonly string _tempCertsDir;
        private readonly string _tempConfigFile;

        public CertGeneratorContainerTests()
        {
            // Create a temporary directory for the generated certificates.
            _tempCertsDir = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(_tempCertsDir);

            // Create a temporary configuration file with minimal YAML configuration.
            // This example instructs the container to generate a certificate named "test-cert".
            _tempConfigFile = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + "-config.yaml");
            var configContent = @"
certificates:
  - name: test-cert
    subject: 'CN=test-cert'
    validityDays: 365
";
            File.WriteAllText(_tempConfigFile, configContent);
        }

        [Fact(DisplayName = "CertGeneratorContainer should generate certificate files successfully")]
        public async Task CertGeneratorContainer_GeneratesCertificates()
        {
            // Build the cert-generator container using the module's builder.
            // It mounts the temporary config file at the expected container path
            // and also binds a temporary directory to capture the generated certs.
            var certContainer = new CertGeneratorBuilder()
                .WithHostConfiguration(_tempConfigFile)
                .WithHostCertificates(_tempCertsDir)
                .Build();

            // Start the container asynchronously.
            await certContainer.StartAsync();

            // After the container finishes, verify that the expected certificate files are present.
            // In this example, we expect the cert-generator to output "test-cert.crt" and "test-cert.key".
            string crtFile = Path.Combine(_tempCertsDir, "test-cert.crt");
            string keyFile = Path.Combine(_tempCertsDir, "test-cert.key");

            Assert.True(File.Exists(crtFile), $"Expected certificate file not found: {crtFile}");
            Assert.True(File.Exists(keyFile), $"Expected key file not found: {keyFile}");

            // Optionally, ensure the generated files are not empty.
            Assert.True(new FileInfo(crtFile).Length > 0, "The certificate file is empty.");
            Assert.True(new FileInfo(keyFile).Length > 0, "The key file is empty.");
        }

        public Task InitializeAsync() => Task.CompletedTask;

        public Task DisposeAsync()
        {
            // Clean up temporary files and directories.
            if (Directory.Exists(_tempCertsDir))
                Directory.Delete(_tempCertsDir, recursive: true);
            
            if (File.Exists(_tempConfigFile))
                File.Delete(_tempConfigFile);

            return Task.CompletedTask;
        }
    }
}