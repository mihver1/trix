#[derive(Debug, Clone)]
pub struct AccountRootMaterial;

#[derive(Debug, Clone)]
pub struct DeviceKeyMaterial;

#[derive(Debug, Default)]
pub struct MlsFacade;

impl MlsFacade {
    pub fn new() -> Self {
        Self
    }
}
